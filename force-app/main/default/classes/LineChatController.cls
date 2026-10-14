/**
 * LWC API for reps (02 §2). Everything a rep can reach goes through here.
 *
 * `with sharing` and user-mode checks: the rep must be able to see the conversation (OWD Private, owner = the OA's rep)
 * and to create messages, before any callout is made. Errors reach the LWC as `AuraHandledException` carrying a
 * Custom Label message; LINE's own message is passed through where it helps the rep (e.g. the monthly limit).
 *
 * Reads are paged with keyset pagination on (`Sent_At__c`, `Id`) and never use OFFSET (D12), so a conversation with
 * a million messages pages as fast as a new one.
 *
 * M4: sending text. M5: conversation and message reads, polling, mark-as-read. M6: link/unlink from the chat panel
 * (DEC-44) and QR invites. M7: sending files.
 */
public with sharing class LineChatController {
  @TestVisible
  static final Integer DEFAULT_PAGE_SIZE = 30;
  @TestVisible
  static final Integer MAX_PAGE_SIZE = 100;
  // A poll returns only what arrived since the last one; this cap is a safety net, not a normal case.
  @TestVisible
  static final Integer MAX_NEW_MESSAGES = 200;
  private static final Integer MAX_INVITE_ATTEMPTS = 5;
  // The last error turned into a generic message, so tests can show what really happened.
  @TestVisible
  static Exception lastUnexpectedError;

  /** One message, as shown in the chat panel. Never contains secrets. */
  public class MessageView {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String direction;
    @AuraEnabled
    public Boolean isOutbound;
    @AuraEnabled
    public String messageType;
    @AuraEnabled
    public String text;
    @AuraEnabled
    public Datetime sentAt;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String errorMessage;
    @AuraEnabled
    public Id senderId;
    @AuraEnabled
    public String senderName;
    @AuraEnabled
    public String fileName;
    @AuraEnabled
    public Decimal fileSize;
    @AuraEnabled
    public String publicUrl;
    @AuraEnabled
    public String contentDocumentId;
    /** The file's latest version, for its thumbnail (M7); null when the user can't see the file. */
    @AuraEnabled
    public String contentVersionId;
    @AuraEnabled
    public String stickerPackageId;
    @AuraEnabled
    public String stickerId;
    /** The sticker's picture on LINE's CDN (DEC-32); null for other messages or an unusable ID. */
    @AuraEnabled
    public String stickerUrl;
    @AuraEnabled
    public String location;

    private MessageView(LINE_Message__c m) {
      this.id = m.Id;
      this.direction = m.Direction__c;
      this.isOutbound = m.Direction__c == 'Outbound';
      this.messageType = m.Message_Type__c;
      this.text = m.Text__c;
      this.sentAt = m.Sent_At__c;
      this.status = m.Status__c;
      this.errorMessage = m.Error__c;
      this.senderId = m.Sender__c;
      this.senderName = m.Sender__r?.Name;
      this.fileName = m.File_Name__c;
      this.fileSize = m.File_Size__c;
      this.publicUrl = m.Public_Url__c;
      this.contentDocumentId = m.Content_Document_Id__c;
      this.stickerPackageId = m.Sticker_Package_Id__c;
      this.stickerId = m.Sticker_Id__c;
      this.stickerUrl = m.Message_Type__c == 'sticker'
        ? LineApiClient.stickerImageUrl(m.Sticker_Id__c)
        : null;
      this.location = m.Location__c;
    }
  }

  /** One conversation of a Contact, for the chat panel's OA selector. */
  public class ConversationView {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String pictureUrl;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Decimal unreadCount;
    @AuraEnabled
    public Datetime lastMessageAt;
    @AuraEnabled
    public Id oaConfigurationId;
    @AuraEnabled
    public String oaName;
    @AuraEnabled
    public Boolean isPrimaryOa;
    /** Whether the running user may reply in this conversation (DEC-37); the panel is read-only otherwise. */
    @AuraEnabled
    public Boolean canSend = false;
    /** The linked Contact, or null while the conversation is unlinked. */
    @AuraEnabled
    public Id contactId;
    @AuraEnabled
    public String contactName;
    @AuraEnabled
    public String lastMessagePreview;
    /** Admins may unlink (03 §5 rule 4). */
    @AuraEnabled
    public Boolean canUnlink = false;

    private ConversationView(LINE_Conversation__c c, Id primaryOaId) {
      this.id = c.Id;
      this.name = c.Name;
      this.pictureUrl = c.Picture_Url__c;
      this.status = c.Status__c;
      this.unreadCount = c.Unread_Count__c == null ? 0 : c.Unread_Count__c;
      this.lastMessageAt = c.Last_Message_At__c;
      this.oaConfigurationId = c.LINE_OA_Configuration__c;
      this.oaName = c.LINE_OA_Configuration__r?.Name;
      this.isPrimaryOa =
        primaryOaId != null &&
        primaryOaId == c.LINE_OA_Configuration__c;
      this.contactId = c.Contact__c;
      this.contactName = c.Contact__r?.Name;
      this.lastMessagePreview = c.Last_Message_Preview__c;
    }
  }

  /** One sticker the rep can send, with its picture (DEC-44). */
  public class StickerView {
    @AuraEnabled
    public String packageId;
    @AuraEnabled
    public String stickerId;
    @AuraEnabled
    public String url;
  }

  /** One sticker package for the picker. */
  public class StickerPackView {
    @AuraEnabled
    public String packageId;
    @AuraEnabled
    public List<StickerView> stickers = new List<StickerView>();
  }

  /** A QR invite for a Contact (03 §5 rule 5). */
  public class InviteView {
    @AuraEnabled
    public String url;
    @AuraEnabled
    public String code;
    @AuraEnabled
    public Datetime expiresAt;
    @AuraEnabled
    public String oaName;
  }

  /** What linking did, for the rep's confirmation. */
  public class LinkView {
    @AuraEnabled
    public ConversationView conversation;
    @AuraEnabled
    public Boolean placeholderDeleted = false;
    @AuraEnabled
    public Boolean placeholderKept = false;
  }

  /** One page of messages, oldest first. */
  public class MessagePage {
    @AuraEnabled
    public List<MessageView> messages = new List<MessageView>();
    /** True when older messages exist before this page. */
    @AuraEnabled
    public Boolean hasMore = false;
  }

  /**
   * Conversations of a Contact that the running user can see, the Contact's primary OA first, then most recent.
   *
   * @param contactId the Contact whose chat panel is open
   * @return the conversations, or an empty list when the Contact has none the user can see
   */
  @AuraEnabled
  public static List<ConversationView> getConversations(Id contactId) {
    try {
      if (contactId == null) {
        return new List<ConversationView>();
      }
      Id primaryOaId = primaryOaOf(contactId);
      List<ConversationView> result = new List<ConversationView>();
      for (LINE_Conversation__c c : [
        SELECT
          Id,
          Name,
          Picture_Url__c,
          Status__c,
          Unread_Count__c,
          Last_Message_At__c,
          LINE_OA_Configuration__c,
          LINE_OA_Configuration__r.Name,
          Contact__c,
          Contact__r.Name,
          Last_Message_Preview__c
        FROM LINE_Conversation__c
        WHERE Contact__c = :contactId
        WITH USER_MODE
        ORDER BY Last_Message_At__c DESC NULLS LAST, Name
        LIMIT 50
      ]) {
        result.add(new ConversationView(c, primaryOaId));
      }
      Set<Id> oaIds = new Set<Id>();
      for (ConversationView view : result) {
        oaIds.add(view.oaConfigurationId);
      }
      Set<Id> sendable = sendableOaIds(oaIds, UserInfo.getUserId());
      Boolean isAdmin = FeatureManagement.checkPermission('LINE_Admin');
      for (ConversationView view : result) {
        view.canSend = sendable.contains(view.oaConfigurationId);
        view.canUnlink = isAdmin;
      }
      // The Contact's primary OA opens first (03 §2); the rest keep their most-recent-first order.
      for (Integer i = 1; i < result.size(); i++) {
        if (result[i].isPrimaryOa) {
          List<ConversationView> reordered = new List<ConversationView>{
            result.remove(i)
          };
          reordered.addAll(result);
          return reordered;
        }
      }
      return result;
    } catch (Exception e) {
      throw handled(e, 'getConversations', contactId);
    }
  }

  /**
   * One conversation, as the chat panel shows it (used after linking or unlinking).
   *
   * @param conversationId the conversation
   * @return the conversation, including whether the user may reply
   */
  @AuraEnabled
  public static ConversationView getConversation(Id conversationId) {
    try {
      List<ConversationView> found = conversationViews(
        new Set<Id>{ conversationId }
      );
      if (found.isEmpty()) {
        throw asAuraException(System.Label.LINE_Error_No_Access);
      }
      return found[0];
    } catch (Exception e) {
      throw handled(e, 'getConversation', conversationId);
    }
  }

  /**
   * Links a conversation to a Contact (03 §5 rule 3, DEC-34). The rep must be able to read the conversation and edit
   * the Contact; the rules themselves live in `LineLinkService`.
   *
   * @param conversationId the conversation
   * @param contactId the Contact chosen by the rep
   * @return the linked conversation and what happened to an auto-created placeholder
   */
  @AuraEnabled
  public static LinkView linkToContact(Id conversationId, Id contactId) {
    try {
      assertCanRead(conversationId);
      assertCanEditContact(contactId);
      LineLinkService.LinkResult result;
      try {
        result = LineLinkService.linkToContact(conversationId, contactId);
      } catch (LineLinkService.LinkException refused) {
        throw asAuraException(refusalMessage(refused));
      }
      LinkView view = new LinkView();
      view.conversation = getConversation(conversationId);
      view.placeholderDeleted = result.placeholderDeleted;
      view.placeholderKept = result.placeholderKeptId != null;
      return view;
    } catch (Exception e) {
      throw handled(e, 'linkToContact', conversationId);
    } finally {
      LineLogger.flush();
    }
  }

  /**
   * Creates a one-time QR invite for a Contact (03 §5 rule 5, D10): a fresh code replaces any earlier one, and the
   * link opens the rep's OA. The rep must be able to edit the Contact and own an active OA.
   *
   * @param contactId the Contact to invite
   * @return the link to show as a QR code, its code and expiry
   */
  @AuraEnabled
  public static InviteView createInvite(Id contactId) {
    try {
      assertCanEditContact(contactId);
      LINE_OA_Configuration__c oa = inviteOa(contactId);
      if (oa == null || String.isBlank(oa.Basic_Id__c)) {
        throw asAuraException(System.Label.LINE_Invite_No_OA);
      }
      Datetime expiresAt = Datetime.now()
        .addDays(LineSettings.inviteCodeExpiryDays());
      String code = saveNewInviteCode(contactId, expiresAt);
      InviteView view = new InviteView();
      view.code = code;
      view.expiresAt = expiresAt;
      view.oaName = oa.Name;
      view.url = LineApiClient.oaMessageUrl(
        oa.Basic_Id__c,
        String.format(
          System.Label.LINE_Invite_Message,
          new List<Object>{ code }
        )
      );
      return view;
    } catch (Exception e) {
      throw handled(e, 'createInvite', contactId);
    }
  }

  // The Contact's primary OA when this rep runs it, otherwise the rep's own active OA (03 §5 rule 5).
  private static LINE_OA_Configuration__c inviteOa(Id contactId) {
    Id me = UserInfo.getUserId();
    List<Contact> contacts = [
      SELECT LINE_OA_Configuration__c
      FROM Contact
      WHERE Id = :contactId
      WITH USER_MODE
      LIMIT 1
    ];
    Id primaryOaId = contacts.isEmpty()
      ? null
      : contacts[0].LINE_OA_Configuration__c;
    LINE_OA_Configuration__c fallback;
    for (LINE_OA_Configuration__c oa : [
      SELECT Id, Name, Basic_Id__c
      FROM LINE_OA_Configuration__c
      WHERE Assigned_Rep__c = :me AND Is_Active__c = TRUE
      WITH USER_MODE
      ORDER BY CreatedDate
      LIMIT 50
    ]) {
      if (oa.Id == primaryOaId) {
        return oa;
      }
      if (fallback == null) {
        fallback = oa;
      }
    }
    return fallback;
  }

  // The code is unique: on the rare collision, draw again (03 §5 rule 5). Saved as the user, who holds Edit on the
  // invite fields through LINE_Chat_User.
  private static String saveNewInviteCode(Id contactId, Datetime expiresAt) {
    for (Integer attempt = 0; attempt < MAX_INVITE_ATTEMPTS; attempt++) {
      String code = LineLinkService.newInviteCode();
      Database.SaveResult saved = Database.update(
        new Contact(
          Id = contactId,
          LINE_Invite_Code__c = code,
          LINE_Invite_Expires_At__c = expiresAt
        ),
        false,
        AccessLevel.USER_MODE
      );
      if (saved.isSuccess()) {
        return code;
      }
      if (saved.getErrors()[0].getStatusCode() != StatusCode.DUPLICATE_VALUE) {
        throw asAuraException(
          String.format(
            System.Label.LINE_Link_Failed,
            new List<Object>{ saved.getErrors()[0].getMessage() }
          )
        );
      }
    }
    throw asAuraException(System.Label.LINE_Error_Generic);
  }

  /**
   * Unlinks a conversation from its Contact (03 §5 rule 4). Admins only.
   *
   * @param conversationId the conversation
   * @return the conversation, now unlinked
   */
  @AuraEnabled
  public static ConversationView unlinkConversation(Id conversationId) {
    try {
      if (!FeatureManagement.checkPermission('LINE_Admin')) {
        throw asAuraException(System.Label.LINE_Error_Admin_Only);
      }
      assertCanRead(conversationId);
      LineLinkService.unlink(conversationId);
      return getConversation(conversationId);
    } catch (Exception e) {
      throw handled(e, 'unlinkConversation', conversationId);
    }
  }

  // Thumbnails need a version Id; read as the user, so a file they can't see shows no picture.
  private static void addFileVersions(List<MessageView> views) {
    Set<Id> documentIds = new Set<Id>();
    for (MessageView view : views) {
      if (String.isNotBlank(view.contentDocumentId)) {
        documentIds.add(Id.valueOf(view.contentDocumentId));
      }
    }
    if (documentIds.isEmpty()) {
      return;
    }
    Map<Id, ContentDocument> documents = new Map<Id, ContentDocument>(
      [
        SELECT Id, LatestPublishedVersionId
        FROM ContentDocument
        WHERE Id IN :documentIds
        WITH USER_MODE
      ]
    );
    for (MessageView view : views) {
      ContentDocument d = String.isBlank(view.contentDocumentId)
        ? null
        : documents.get(Id.valueOf(view.contentDocumentId));
      view.contentVersionId = d?.LatestPublishedVersionId;
    }
  }

  // Views for conversations the user can see, with canSend filled in.
  private static List<ConversationView> conversationViews(Set<Id> ids) {
    List<ConversationView> result = new List<ConversationView>();
    if (ids.isEmpty()) {
      return result;
    }
    for (LINE_Conversation__c c : [
      SELECT
        Id,
        Name,
        Picture_Url__c,
        Status__c,
        Unread_Count__c,
        Last_Message_At__c,
        LINE_OA_Configuration__c,
        LINE_OA_Configuration__r.Name,
        Contact__c,
        Contact__r.Name,
        Last_Message_Preview__c
      FROM LINE_Conversation__c
      WHERE Id IN :ids
      WITH USER_MODE
    ]) {
      result.add(new ConversationView(c, null));
    }
    Set<Id> oaIds = new Set<Id>();
    for (ConversationView view : result) {
      oaIds.add(view.oaConfigurationId);
    }
    Set<Id> sendable = sendableOaIds(oaIds, UserInfo.getUserId());
    Boolean isAdmin = FeatureManagement.checkPermission('LINE_Admin');
    for (ConversationView view : result) {
      view.canSend = sendable.contains(view.oaConfigurationId);
      view.canUnlink = isAdmin;
    }
    return result;
  }

  // Edit on the Contact, by sharing and by object permission, checked as the user.
  private static void assertCanEditContact(Id contactId) {
    if (
      contactId == null ||
      contactId.getSObjectType() != Contact.SObjectType ||
      !Schema.SObjectType.Contact.isUpdateable()
    ) {
      throw asAuraException(System.Label.LINE_Link_No_Edit);
    }
    List<UserRecordAccess> access = [
      SELECT RecordId, HasEditAccess
      FROM UserRecordAccess
      WHERE UserId = :UserInfo.getUserId() AND RecordId = :contactId
      WITH USER_MODE
      LIMIT 1
    ];
    if (access.isEmpty() || !access[0].HasEditAccess) {
      throw asAuraException(System.Label.LINE_Link_No_Edit);
    }
  }

  // Names the Contact already holding the LINE user ID only when the user may see it (03 §5 rule 3).
  private static String refusalMessage(LineLinkService.LinkException refused) {
    if (refused.holderId == null) {
      return refused.getMessage();
    }
    List<Contact> visible = [
      SELECT Name
      FROM Contact
      WHERE Id = :refused.holderId
      WITH USER_MODE
      LIMIT 1
    ];
    return visible.isEmpty()
      ? refused.getMessage()
      : String.format(
          System.Label.LINE_Link_Held_By,
          new List<Object>{ visible[0].Name }
        );
  }

  /**
   * One page of older messages, oldest first. Pass the oldest message you already have to get the page before it.
   *
   * @param conversationId the open conversation
   * @param beforeSentAt `sentAt` of the oldest message held, or null for the newest page
   * @param beforeId Id of that same message, which breaks ties on equal timestamps
   * @param pageSize how many to return (default 30, maximum 100)
   * @return the page, plus whether older messages remain
   */
  @AuraEnabled
  public static MessagePage getMessages(
    Id conversationId,
    Datetime beforeSentAt,
    Id beforeId,
    Integer pageSize
  ) {
    try {
      assertCanRead(conversationId);
      Integer size = pageSize == null ||
        pageSize <= 0
        ? DEFAULT_PAGE_SIZE
        : Math.min(pageSize, MAX_PAGE_SIZE);
      // One extra row tells us whether an older page exists, without a COUNT().
      Integer queryLimit = size + 1;
      Datetime before = beforeSentAt == null
        ? Datetime.newInstance(4000, 1, 1)
        : beforeSentAt;
      Id beforeRecordId = beforeId == null
        ? (Id) '000000000000000AAA'
        : beforeId;

      List<LINE_Message__c> rows = [
        SELECT
          Id,
          Direction__c,
          Message_Type__c,
          Text__c,
          Sent_At__c,
          Status__c,
          Error__c,
          Sender__c,
          Sender__r.Name,
          File_Name__c,
          File_Size__c,
          Public_Url__c,
          Content_Document_Id__c,
          Sticker_Package_Id__c,
          Sticker_Id__c,
          Location__c
        FROM LINE_Message__c
        WHERE
          LINE_Conversation__c = :conversationId
          AND (Sent_At__c < :before
          OR (Sent_At__c = :before
          AND Id < :beforeRecordId))
        WITH USER_MODE
        ORDER BY Sent_At__c DESC, Id DESC
        LIMIT :queryLimit
      ];

      MessagePage page = new MessagePage();
      page.hasMore = rows.size() > size;
      if (page.hasMore) {
        rows.remove(rows.size() - 1);
      }
      // Queried newest first for the LIMIT; the panel wants oldest first.
      for (Integer i = rows.size() - 1; i >= 0; i--) {
        page.messages.add(new MessageView(rows[i]));
      }
      addFileVersions(page.messages);
      return page;
    } catch (Exception e) {
      throw handled(e, 'getMessages', conversationId);
    }
  }

  /**
   * Messages that arrived after the newest one the panel holds. Used by polling (D7).
   *
   * @param conversationId the open conversation
   * @param afterSentAt `sentAt` of the newest message held
   * @param afterId Id of that same message
   * @return the new messages, oldest first
   */
  @AuraEnabled
  public static List<MessageView> getMessagesSince(
    Id conversationId,
    Datetime afterSentAt,
    Id afterId
  ) {
    try {
      assertCanRead(conversationId);
      Datetime after = afterSentAt == null
        ? Datetime.newInstance(1970, 1, 1)
        : afterSentAt;
      Id afterRecordId = afterId == null ? (Id) '000000000000000AAA' : afterId;

      List<MessageView> result = new List<MessageView>();
      for (LINE_Message__c m : [
        SELECT
          Id,
          Direction__c,
          Message_Type__c,
          Text__c,
          Sent_At__c,
          Status__c,
          Error__c,
          Sender__c,
          Sender__r.Name,
          File_Name__c,
          File_Size__c,
          Public_Url__c,
          Content_Document_Id__c,
          Sticker_Package_Id__c,
          Sticker_Id__c,
          Location__c
        FROM LINE_Message__c
        WHERE
          LINE_Conversation__c = :conversationId
          AND (Sent_At__c > :after
          OR (Sent_At__c = :after
          AND Id > :afterRecordId))
        WITH USER_MODE
        ORDER BY Sent_At__c ASC, Id ASC
        LIMIT :MAX_NEW_MESSAGES
      ]) {
        result.add(new MessageView(m));
      }
      addFileVersions(result);
      return result;
    } catch (Exception e) {
      throw handled(e, 'getMessagesSince', conversationId);
    }
  }

  /**
   * Clears the unread count of a conversation the rep is reading.
   *
   * @param conversationId the open conversation
   * @return the conversation's unread count afterwards (0)
   */
  @AuraEnabled
  public static Decimal markRead(Id conversationId) {
    try {
      assertCanRead(conversationId);
      update as user new LINE_Conversation__c(
        Id = conversationId,
        Unread_Count__c = 0
      );
      return 0;
    } catch (Exception e) {
      throw handled(e, 'markRead', conversationId);
    }
  }

  /**
   * @return how often the panel should poll, in seconds (`LINE_Settings__c`, default 5)
   */
  @AuraEnabled(cacheable=true)
  public static Integer getPollIntervalSeconds() {
    return LineSettings.pollIntervalSeconds();
  }

  /**
   * Sends a text message to the customer of a conversation, through that conversation's OA.
   *
   * @param conversationId the conversation the rep has open
   * @param text 1–5,000 characters
   * @return the stored message
   * @throws AuraHandledException if the rep can't access the conversation, the text is invalid, or LINE refuses
   */
  @AuraEnabled
  public static MessageView sendText(Id conversationId, String text) {
    try {
      assertCanSend(conversationId);
      return new MessageView(
        LineOutboundService.sendText(conversationId, text)
      );
    } catch (Exception e) {
      // LINE's own wording is the most useful thing for the rep (monthly limit, text too long, …).
      throw handled(e, 'sendText', conversationId);
    }
  }

  /**
   * The OAs the user may send through (DEC-37, TA review R1). Seeing a conversation is not enough: a message goes out
   * under the rep's OA, and the customer can't tell who typed it. An active OA sends only as its assigned rep; an
   * inactive OA's conversations belong to the fallback owner (03 §2), so that user, or a member of that queue, may reply.
   *
   * Reads the OA's routing fields in system mode on purpose: the decision must not depend on whether a subscriber has
   * narrowed OA sharing, and nothing read here is returned except the yes/no.
   */
  @TestVisible
  private static Set<Id> sendableOaIds(Set<Id> oaIds, Id userId) {
    Set<Id> result = new Set<Id>();
    oaIds.remove(null);
    if (oaIds.isEmpty() || userId == null) {
      return result;
    }
    Boolean isFallback;
    for (LINE_OA_Configuration__c oa : [
      SELECT Id, Assigned_Rep__c, Is_Active__c
      FROM LINE_OA_Configuration__c
      WHERE Id IN :oaIds
      WITH SYSTEM_MODE
    ]) {
      if (oa.Is_Active__c) {
        if (oa.Assigned_Rep__c == userId) {
          result.add(oa.Id);
        }
        continue;
      }
      if (isFallback == null) {
        isFallback = isFallbackOwner(userId);
      }
      if (isFallback) {
        result.add(oa.Id);
      }
    }
    return result;
  }

  // Direct queue members only; a fallback queue is a small, admin-chosen group.
  private static Boolean isFallbackOwner(Id userId) {
    Id fallback = LineSettings.fallbackOwnerId();
    if (fallback == null) {
      return false;
    }
    if (fallback == userId) {
      return true;
    }
    if (fallback.getSObjectType() != Group.SObjectType) {
      return false;
    }
    return [
        SELECT COUNT()
        FROM GroupMember
        WHERE GroupId = :fallback AND UserOrGroupId = :userId
        WITH SYSTEM_MODE
      ] > 0;
  }

  /**
   * Step 1 of sending a file (M7): gives the uploaded file an expiring public link. Called by the panel right after
   * the upload, then `sendFile`; two calls because the link is a write and the push must come before any write.
   *
   * @param conversationId the open conversation the file was uploaded to
   * @param contentDocumentId the uploaded file
   */
  @AuraEnabled
  public static void prepareFile(Id conversationId, Id contentDocumentId) {
    try {
      assertCanSend(conversationId);
      assertCanSeeFile(contentDocumentId);
      LineOutboundService.createPublicLink(conversationId, contentDocumentId);
    } catch (Exception e) {
      throw handled(e, 'prepareFile', conversationId);
    }
  }

  /**
   * Step 2 of sending a file (M7): pushes it to the customer, as a picture or as a link (DEC-43).
   *
   * @param conversationId the open conversation
   * @param contentDocumentId the uploaded file
   * @return the stored message
   */
  @AuraEnabled
  public static MessageView sendFile(Id conversationId, Id contentDocumentId) {
    try {
      assertCanSend(conversationId);
      assertCanSeeFile(contentDocumentId);
      MessageView view = new MessageView(
        LineOutboundService.sendFile(conversationId, contentDocumentId)
      );
      addFileVersions(new List<MessageView>{ view });
      return view;
    } catch (Exception e) {
      throw handled(e, 'sendFile', conversationId);
    }
  }

  /**
   * The stickers LINE lets bots send, for the panel's picker (DEC-44). Static data; pictures come from LINE's sticker
   * server through the packaged CSP Trusted Site (DEC-32).
   *
   * @return the sticker packages in display order
   */
  @AuraEnabled(cacheable=true)
  public static List<StickerPackView> getStickerCatalog() {
    List<StickerPackView> result = new List<StickerPackView>();
    Map<String, List<String>> sendable = LineOutboundService.sendableStickers();
    for (String packageId : sendable.keySet()) {
      StickerPackView pack = new StickerPackView();
      pack.packageId = packageId;
      for (String stickerId : sendable.get(packageId)) {
        StickerView sticker = new StickerView();
        sticker.packageId = packageId;
        sticker.stickerId = stickerId;
        sticker.url = LineApiClient.stickerImageUrl(stickerId);
        pack.stickers.add(sticker);
      }
      result.add(pack);
    }
    return result;
  }

  /**
   * Sends a sticker to the customer (DEC-44).
   *
   * @param conversationId the open conversation
   * @param packageId sticker package, from `getStickerCatalog`
   * @param stickerId sticker, from `getStickerCatalog`
   * @return the stored message
   */
  @AuraEnabled
  public static MessageView sendSticker(
    Id conversationId,
    String packageId,
    String stickerId
  ) {
    try {
      assertCanSend(conversationId);
      return new MessageView(
        LineOutboundService.sendSticker(conversationId, packageId, stickerId)
      );
    } catch (Exception e) {
      throw handled(e, 'sendSticker', conversationId);
    }
  }

  private static void assertCanSeeFile(Id contentDocumentId) {
    if (contentDocumentId == null) {
      throw asAuraException(System.Label.LINE_Error_No_Access);
    }
    Integer visible = [
      SELECT COUNT()
      FROM ContentDocument
      WHERE Id = :contentDocumentId
      WITH USER_MODE
    ];
    if (visible == 0) {
      throw asAuraException(System.Label.LINE_Error_No_Access);
    }
  }

  // The rep must see the conversation (sharing) and be able to create messages (object/field access), in user mode.
  private static void assertCanSend(Id conversationId) {
    if (conversationId == null) {
      throw asAuraException(System.Label.LINE_Error_No_Access);
    }
    List<LINE_Conversation__c> conversations = [
      SELECT Id, Status__c, LINE_OA_Configuration__c
      FROM LINE_Conversation__c
      WHERE Id = :conversationId
      WITH USER_MODE
      LIMIT 1
    ];
    if (conversations.isEmpty()) {
      throw asAuraException(System.Label.LINE_Error_No_Access);
    }
    if (
      !sendableOaIds(
          new Set<Id>{ conversations[0].LINE_OA_Configuration__c },
          UserInfo.getUserId()
        )
        .contains(conversations[0].LINE_OA_Configuration__c)
    ) {
      throw asAuraException(System.Label.LINE_Chat_Not_Assigned_Rep);
    }
    // Object level only: the message is written in system mode by LineOutboundService, and the permission sets
    // deliberately keep message fields read-only for reps (03 §6), so a field-level create check would never pass.
    if (!Schema.SObjectType.LINE_Message__c.isCreateable()) {
      throw asAuraException(System.Label.LINE_Error_No_Access);
    }
    if (conversations[0].Status__c == 'Unfollowed') {
      throw asAuraException(System.Label.LINE_Error_Conversation_Inactive);
    }
  }

  // Sharing decides this: a rep only sees conversations they own (or their team's, through the role hierarchy).
  private static void assertCanRead(Id conversationId) {
    if (conversationId == null) {
      throw asAuraException(System.Label.LINE_Error_No_Access);
    }
    List<LINE_Conversation__c> found = [
      SELECT Id
      FROM LINE_Conversation__c
      WHERE Id = :conversationId
      WITH USER_MODE
      LIMIT 1
    ];
    if (found.isEmpty()) {
      throw asAuraException(System.Label.LINE_Error_No_Access);
    }
  }

  // Null when the Contact isn't readable or has no primary OA; only used for ordering.
  private static Id primaryOaOf(Id contactId) {
    List<Contact> contacts = [
      SELECT LINE_OA_Configuration__c
      FROM Contact
      WHERE Id = :contactId
      WITH USER_MODE
      LIMIT 1
    ];
    return contacts.isEmpty() ? null : contacts[0].LINE_OA_Configuration__c;
  }

  // One place to turn any failure into something the LWC can show, without leaking internals.
  private static AuraHandledException handled(
    Exception e,
    String method,
    Id recordId
  ) {
    if (e instanceof AuraHandledException) {
      return (AuraHandledException) e;
    }
    if (e instanceof LineApiException) {
      return asAuraException(((LineApiException) e).userMessage());
    }
    if (e instanceof IllegalArgumentException) {
      return asAuraException(e.getMessage());
    }
    if (e instanceof QueryException || e instanceof System.NoAccessException) {
      // WITH USER_MODE raises these when the user lacks object or field access.
      return asAuraException(System.Label.LINE_Error_No_Access);
    }
    lastUnexpectedError = e;
    LineLogger.error('LineChatController.' + method, e, null, recordId);
    LineLogger.flush();
    return asAuraException(System.Label.LINE_Error_Generic);
  }

  private static AuraHandledException asAuraException(String message) {
    AuraHandledException e = new AuraHandledException(message);
    // Without this, the LWC only sees "Script-thrown exception".
    e.setMessage(message);
    return e;
  }
}
