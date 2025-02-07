//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

public protocol CloudBackupChatArchiver: CloudBackupProtoArchiver {

    typealias ChatId = CloudBackup.ChatId

    typealias ArchiveMultiFrameResult = CloudBackup.ArchiveMultiFrameResult<ChatId>

    /// Archive all ``TSThread``s (they map to ``BackupProtoChat``).
    ///
    /// - Returns: ``ArchiveMultiFrameResult.success`` if all frames were written without error, or either
    /// partial or complete failure otherwise.
    /// How to handle ``ArchiveMultiFrameResult.partialSuccess`` is up to the caller,
    /// but typically an error will be shown to the user, but the backup will be allowed to proceed.
    /// ``ArchiveMultiFrameResult.completeFailure``, on the other hand, will stop the entire backup,
    /// and should be used if some critical or category-wide failure occurs.
    func archiveChats(
        stream: CloudBackupProtoOutputStream,
        context: CloudBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> ArchiveMultiFrameResult

    typealias RestoreFrameResult = CloudBackup.RestoreFrameResult<ChatId>

    /// Restore a single ``BackupProtoChat`` frame.
    ///
    /// - Returns: ``RestoreFrameResult.success`` if all frames were read without error.
    /// How to handle ``RestoreFrameResult.failure`` is up to the caller,
    /// but typically an error will be shown to the user, but the restore will be allowed to proceed.
    func restore(
        _ chat: BackupProtoChat,
        context: CloudBackup.ChatRestoringContext,
        tx: DBWriteTransaction
    ) -> RestoreFrameResult
}

public class CloudBackupChatArchiverImpl: CloudBackupChatArchiver {

    private let dmConfigurationStore: DisappearingMessagesConfigurationStore
    private let threadFetcher: CloudBackup.Shims.TSThreadFetcher

    public init(
        dmConfigurationStore: DisappearingMessagesConfigurationStore,
        threadFetcher: CloudBackup.Shims.TSThreadFetcher
    ) {
        self.dmConfigurationStore = dmConfigurationStore
        self.threadFetcher = threadFetcher
    }

    // MARK: - Archiving

    public func archiveChats(
        stream: CloudBackupProtoOutputStream,
        context: CloudBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> ArchiveMultiFrameResult {
        var completeFailureError: Error?
        var partialErrors = [ArchiveMultiFrameResult.Error]()

        // TODO: clean up this shim, and just index non-story threads to begin with.
        threadFetcher.enumerateAll(tx: tx) { thread, stop in
            let result: ArchiveMultiFrameResult
            if let thread = thread as? TSContactThread {
                result = self.archiveContactThread(
                    thread,
                    stream: stream,
                    context: context,
                    tx: tx
                )
            } else if let thread = thread as? TSGroupThread {
                result = self.archiveGroupThread(
                    thread,
                    stream: stream,
                    context: context,
                    tx: tx
                )
            } else {
                // Skip other threads.
                // TODO: skip other threads at the SQL level, debug assert here.
                return
            }

            switch result {
            case .success:
                break
            case .completeFailure(let error):
                completeFailureError = error
                stop.pointee = true
            case .partialSuccess(let errors):
                partialErrors.append(contentsOf: errors)
            }
        }

        if let completeFailureError {
            return .completeFailure(completeFailureError)
        } else if partialErrors.isEmpty {
            return .success
        } else {
            return .partialSuccess(partialErrors)
        }
    }

    private func archiveContactThread(
        _ thread: TSContactThread,
        stream: CloudBackupProtoOutputStream,
        context: CloudBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> CloudBackupChatArchiver.ArchiveMultiFrameResult {
        let chatId = context.assignChatId(to: thread.uniqueIdentifier)

        let contactServiceId = thread.contactUUID.map { try? ServiceId.parseFrom(serviceIdString: $0) }
        let recipientAddress: CloudBackup.RecipientArchivingContext.Address
        if
            let aci = contactServiceId as? Aci
        {
            recipientAddress = .contactAci(aci)
        } else if
            let pni = contactServiceId as? Pni
        {
            recipientAddress = .contactPni(pni)
        } else if
            let phoneNumber = thread.contactPhoneNumber,
            let e164 = E164(phoneNumber)
        {
            recipientAddress = .contactE164(e164)
        } else {
            return .partialSuccess([.init(
                objectId: chatId,
                error: .contactThreadMissingAddress
            )])
        }

        guard let recipientId = context.recipientContext[recipientAddress] else {
            return .partialSuccess([.init(
                objectId: chatId,
                error: .referencedIdMissing(.recipient(recipientAddress))
            )])
        }

        return archiveThread(
            thread,
            chatId: chatId,
            recipientId: recipientId,
            stream: stream,
            context: context,
            tx: tx
        )
    }

    private func archiveGroupThread(
        _ thread: TSGroupThread,
        stream: CloudBackupProtoOutputStream,
        context: CloudBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> CloudBackupChatArchiver.ArchiveMultiFrameResult {
        let chatId = context.assignChatId(to: thread.uniqueIdentifier)

        let recipientAddress = CloudBackup.RecipientArchivingContext.Address.group(thread.groupId)
        guard let recipientId = context.recipientContext[recipientAddress] else {
            return .partialSuccess([.init(
                objectId: chatId,
                error: .referencedIdMissing(.recipient(recipientAddress))
            )])
        }

        return archiveThread(
            thread,
            chatId: chatId,
            recipientId: recipientId,
            stream: stream,
            context: context,
            tx: tx
        )
    }

    private func archiveThread<T: TSThread>(
        _ thread: T,
        chatId: ChatId,
        recipientId: CloudBackup.RecipientId,
        stream: CloudBackupProtoOutputStream,
        context: CloudBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> CloudBackupChatArchiver.ArchiveMultiFrameResult {
        let threadAssociatedData = threadFetcher.fetchOrDefaultThreadAssociatedData(for: thread, tx: tx)

        // TODO: actually use the pinned thread order, instead of just
        // assigning in the order we see them in the db table.
        let thisThreadPinnedOrder: UInt32
        if threadFetcher.isThreadPinned(thread) {
            context.pinnedThreadOrder += 1
            thisThreadPinnedOrder = context.pinnedThreadOrder
        } else {
            // Hardcoded 0 for unpinned.
            thisThreadPinnedOrder = 0
        }

        let expirationTimerSeconds = dmConfigurationStore.durationSeconds(for: thread, tx: tx)

        let chatBuilder = BackupProtoChat.builder(
            id: chatId.value,
            recipientID: recipientId.value,
            archived: threadAssociatedData.isArchived,
            pinnedOrder: thisThreadPinnedOrder,
            expirationTimerMs: UInt64(expirationTimerSeconds * 1000),
            muteUntilMs: threadAssociatedData.mutedUntilTimestamp,
            markedUnread: threadAssociatedData.isMarkedUnread,
            // TODO: this is commented out on storageService? ignoring for now.
            dontNotifyForMentionsIfMuted: false
        )

        let error = Self.writeFrameToStream(stream) { frameBuilder in
            let chatProto = try chatBuilder.build()
            frameBuilder.setChat(chatProto)
            return try frameBuilder.build()
        }
        if let error {
            return .partialSuccess([.init(objectId: chatId, error: error)])
        } else {
            return .success
        }
    }

    // MARK: - Restoring

    public func restore(
        _ chat: BackupProtoChat,
        context: CloudBackup.ChatRestoringContext,
        tx: DBWriteTransaction
    ) -> RestoreFrameResult {
        let thread: TSThread
        switch context.recipientContext[chat.recipientId] {
        case .none:
            return .failure(
                chat.chatId,
                [.identifierNotFound(.recipient(chat.recipientId))]
            )
        case .noteToSelf:
            // TODO: handle note to self chat, create the tsThread
            return .success
        case .group(let groupId):
            // We don't create the group thread here; that happened when parsing the Group Recipient.
            // Instead, just set metadata.
            guard let groupThread = threadFetcher.fetch(groupId: groupId, tx: tx) else {
                return .failure(
                    chat.chatId,
                    [.referencedDatabaseObjectNotFound(.groupThread(groupId: groupId))]
                )
            }
            thread = groupThread
        case let .contact(aci, pni, e164):
            let address = SignalServiceAddress(serviceId: aci ?? pni, phoneNumber: e164?.stringValue)
            thread = threadFetcher.getOrCreateContactThread(with: address, tx: tx)
        }

        context[chat.chatId] = thread.uniqueIdentifier

        var associatedDataNeedsUpdate = false
        var isArchived: Bool?
        var isMarkedUnread: Bool?
        var mutedUntilTimestamp: UInt64?

        // TODO: should probably unarchive if set to false?
        if chat.archived {
            associatedDataNeedsUpdate = true
            isArchived = true
        }
        if chat.markedUnread {
            associatedDataNeedsUpdate = true
            isMarkedUnread = true
        }
        if chat.muteUntilMs != 0 {
            associatedDataNeedsUpdate = true
            mutedUntilTimestamp = chat.muteUntilMs
        }

        if associatedDataNeedsUpdate {
            let threadAssociatedData = threadFetcher.fetchOrDefaultThreadAssociatedData(for: thread, tx: tx)
            threadFetcher.updateAssociatedData(
                threadAssociatedData,
                isArchived: isArchived,
                isMarkedUnread: isMarkedUnread,
                mutedUntilTimestamp: mutedUntilTimestamp,
                tx: tx
            )
        }
        // TODO: recover pinned chat ordering
        if chat.pinnedOrder != 0 {
            do {
                try threadFetcher.pinThread(thread, tx: tx)
            } catch {
                // TODO: how could this fail, and what should we do? Ignore for now.
            }
        }

        if chat.expirationTimerMs != 0 {
            dmConfigurationStore.set(
                token: .init(isEnabled: true, durationSeconds: UInt32(chat.expirationTimerMs / 1000)),
                for: .thread(thread),
                tx: tx
            )
        }

        return .success
    }
}
