/**
 * Sends messages to LINE and records them (02 §4 "Outbound", D8).
 *
 * Callout first, then DML (hard rule 6): the push is made before any record is written, so a failed transaction can
 * never leave a "Sent" row for a message LINE never received. Every attempt is recorded, successful or not, so the rep
 * sees what happened. Pushes carry `X-Line-Retry-Key`, and a 409 ("already accepted") counts as success.
 *
 * `without sharing` (02 §2): callers check the user's access to the conversation in user mode first (see
 * `LineChatController`); this class then writes the message and updates the conversation, which the rep may not own.
 */
// Whole class: the graph engine flags every read and write here as missing sharing/FLS enforcement. That is the
// design (02 §2, SECURITY_NOTES §4): LineChatController checks the rep's access to the conversation and their Create
// on LINE_Message__c in user mode first, then this class records the message and touches the conversation the rep may
// not own. Message fields are deliberately read-only for reps, so a user-mode insert could never work here.
// code-analyzer-suppress(sfge)
public without sharing class LineOutboundService {
  /** LINE's own limit for a text message (04 §3). */
  public static final Integer MAX_TEXT_LENGTH = 5000;
  private static final Integer ERROR_LENGTH = 255;
  private static final Integer PREVIEW_LENGTH = 255;

  /**
   * Sends a text message to the conversation's customer through that conversation's OA.
   *
   * @param conversationId the conversation to reply to
   * @param text 1–5,000 characters
   * @return the stored message (Status `Sent`), with its Id
   * @throws LineApiException when LINE rejects the send; a message with Status `Failed` is stored first
   * @throws IllegalArgumentException when the text or conversation is unusable
   */
  public static LINE_Message__c sendText(Id conversationId, String text) {
    if (String.isBlank(text)) {
      throw new IllegalArgumentException(System.Label.LINE_Error_Message_Empty);
    }
    if (text.length() > MAX_TEXT_LENGTH) {
      throw new IllegalArgumentException(
        String.format(
          System.Label.LINE_Error_Message_Too_Long,
          new List<Object>{ String.valueOf(MAX_TEXT_LENGTH) }
        )
      );
    }
    LINE_Conversation__c conversation = load(conversationId);

    LINE_Message__c message = new LINE_Message__c(
      LINE_Conversation__c = conversation.Id,
      Direction__c = 'Outbound',
      Message_Type__c = 'text',
      Text__c = text,
      Sent_At__c = Datetime.now(),
      Sender__c = UserInfo.getUserId()
    );
    try {
      // 1. Callout
      LineApiModels.PushResult result = LineApiClient.forChannel(
          conversation.LINE_OA_Configuration__r.Channel_Id__c
        )
        .push(
          conversation.LINE_User_Id__c,
          new List<LineApiModels.Message>{ LineApiModels.textMessage(text) },
          null
        );
      // 2. DML
      message.Status__c = 'Sent';
      if (!result.sentMessages.isEmpty()) {
        message.Line_Message_Id__c = result.sentMessages[0].id;
      }
      insert as system message;
      touchConversation(conversation, message);
      return message;
    } catch (LineApiException e) {
      message.Status__c = 'Failed';
      message.Error__c = truncate(e.userMessage(), ERROR_LENGTH);
      insert as system message;
      LineLogger.error(
        'LineOutboundService.sendText',
        e,
        conversation.LINE_OA_Configuration__c,
        conversation.Id
      );
      LineLogger.flush();
      throw e;
    }
  }

  /** LINE's limit for an image's preview (04): our native images use the file itself as the preview. */
  @TestVisible
  static final Integer MAX_NATIVE_IMAGE_BYTES = 1000000;
  private static final Set<String> NATIVE_IMAGE_EXTENSIONS = new Set<String>{
    'jpg',
    'jpeg',
    'png'
  };
  private static final Integer DISTRIBUTION_NAME_LENGTH = 100;

  /**
   * Step 1 of sending a file (M7, DEC-43): an expiring public link to the file's current version. Writes only, so it
   * runs in its own transaction before `sendFile`, whose push must come before any DML (hard rule 6).
   *
   * @param conversationId the conversation the file was uploaded to
   * @param contentDocumentId the uploaded file
   */
  public static void createPublicLink(Id conversationId, Id contentDocumentId) {
    ContentVersion version = uploadedVersion(conversationId, contentDocumentId);
    insert as system new ContentDistribution(
      Name = version.Title.left(DISTRIBUTION_NAME_LENGTH),
      ContentVersionId = version.Id,
      PreferencesAllowViewInBrowser = true,
      PreferencesAllowOriginalDownload = true,
      PreferencesLinkLatestVersion = false,
      PreferencesNotifyOnVisit = false,
      PreferencesPasswordRequired = false,
      PreferencesExpires = true,
      ExpiryDate = Datetime.now().addDays(LineSettings.publicLinkExpiryDays())
    );
  }

  /**
   * Step 2 of sending a file (M7, DEC-43): a JPEG or PNG up to 1 MB goes as a LINE image; anything else as a text
   * message carrying the expiring download link. Callout first, then the message record.
   *
   * @param conversationId the conversation the file was uploaded to
   * @param contentDocumentId the uploaded file, already given a public link by `createPublicLink`
   * @return the stored message
   * @throws LineApiException when LINE rejects the send; a message with Status `Failed` is stored first
   */
  public static LINE_Message__c sendFile(
    Id conversationId,
    Id contentDocumentId
  ) {
    LINE_Conversation__c conversation = load(conversationId);
    ContentVersion version = uploadedVersion(conversationId, contentDocumentId);
    List<ContentDistribution> links = [
      SELECT DistributionPublicUrl, ContentDownloadUrl, ExpiryDate
      FROM ContentDistribution
      WHERE ContentVersionId = :version.Id
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
      LIMIT 1
    ];
    if (links.isEmpty()) {
      throw new IllegalArgumentException(System.Label.LINE_Error_Generic);
    }
    ContentDistribution link = links[0];
    Boolean nativeImage =
      NATIVE_IMAGE_EXTENSIONS.contains(version.FileExtension?.toLowerCase()) &&
      version.ContentSize <= MAX_NATIVE_IMAGE_BYTES;
    LineApiModels.Message outgoing;
    String text;
    if (nativeImage) {
      outgoing = LineApiModels.imageMessage(
        link.ContentDownloadUrl,
        link.ContentDownloadUrl
      );
    } else {
      text = String.format(
        System.Label.LINE_File_Link_Message,
        new List<Object>{
          version.Title,
          link.DistributionPublicUrl,
          link.ExpiryDate == null ? '' : link.ExpiryDate.format()
        }
      );
      outgoing = LineApiModels.textMessage(text);
    }

    LINE_Message__c message = new LINE_Message__c(
      LINE_Conversation__c = conversation.Id,
      Direction__c = 'Outbound',
      Message_Type__c = nativeImage ? 'image' : 'file',
      Text__c = text,
      Sent_At__c = Datetime.now(),
      Sender__c = UserInfo.getUserId(),
      File_Name__c = truncate(
        version.Title + '.' + version.FileExtension,
        PREVIEW_LENGTH
      ),
      File_Size__c = version.ContentSize,
      Content_Document_Id__c = contentDocumentId,
      Public_Url__c = link.DistributionPublicUrl
    );
    try {
      // 1. Callout
      LineApiModels.PushResult result = LineApiClient.forChannel(
          conversation.LINE_OA_Configuration__r.Channel_Id__c
        )
        .push(
          conversation.LINE_User_Id__c,
          new List<LineApiModels.Message>{ outgoing },
          null
        );
      // 2. DML
      message.Status__c = 'Sent';
      if (!result.sentMessages.isEmpty()) {
        message.Line_Message_Id__c = result.sentMessages[0].id;
      }
      insert as system message;
      touchConversation(conversation, message);
      return message;
    } catch (LineApiException e) {
      message.Status__c = 'Failed';
      message.Error__c = truncate(e.userMessage(), ERROR_LENGTH);
      insert as system message;
      LineLogger.error(
        'LineOutboundService.sendFile',
        e,
        conversation.LINE_OA_Configuration__c,
        conversation.Id
      );
      LineLogger.flush();
      throw e;
    }
  }

  // Only a file uploaded to this conversation can be sent from it, so a rep can't push an arbitrary org file.
  private static ContentVersion uploadedVersion(
    Id conversationId,
    Id contentDocumentId
  ) {
    Integer linked = [
      SELECT COUNT()
      FROM ContentDocumentLink
      WHERE
        LinkedEntityId = :conversationId
        AND ContentDocumentId = :contentDocumentId
      WITH SYSTEM_MODE
    ];
    if (linked == 0) {
      throw new IllegalArgumentException(System.Label.LINE_Error_No_Access);
    }
    return [
      SELECT Id, Title, FileExtension, ContentSize
      FROM ContentVersion
      WHERE ContentDocumentId = :contentDocumentId AND IsLatest = TRUE
      WITH SYSTEM_MODE
      LIMIT 1
    ];
  }

  // The caller has already checked the user's access; this read is by Id and in system mode.
  private static LINE_Conversation__c load(Id conversationId) {
    List<LINE_Conversation__c> found = [
      SELECT
        Id,
        LINE_User_Id__c,
        Status__c,
        LINE_OA_Configuration__c,
        LINE_OA_Configuration__r.Channel_Id__c,
        Last_Message_At__c
      FROM LINE_Conversation__c
      WHERE Id = :conversationId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (found.isEmpty()) {
      throw new IllegalArgumentException(System.Label.LINE_Error_Generic);
    }
    if (String.isBlank(found[0].LINE_OA_Configuration__r?.Channel_Id__c)) {
      throw new IllegalArgumentException(System.Label.LINE_Error_Generic);
    }
    return found[0];
  }

  // Keeps the inbox ordering and preview in step with what the rep just sent.
  private static void touchConversation(
    LINE_Conversation__c conversation,
    LINE_Message__c message
  ) {
    Database.SaveResult result = Database.update(
      new LINE_Conversation__c(
        Id = conversation.Id,
        Last_Message_At__c = message.Sent_At__c,
        Last_Message_Preview__c = truncate(
          message.Message_Type__c == 'text'
            ? message.Text__c
            : message.File_Name__c,
          PREVIEW_LENGTH
        )
      ),
      false,
      AccessLevel.SYSTEM_MODE
    );
    if (!result.isSuccess()) {
      // The message is sent and stored; a stale preview must not fail the send.
      LineLogger.error(
        'LineOutboundService.touchConversation',
        String.valueOf(result.getErrors()),
        conversation.LINE_OA_Configuration__c,
        conversation.Id
      );
      LineLogger.flush();
    }
  }

  private static String truncate(String value, Integer maxLength) {
    return value == null ||
      value.length() <= maxLength
      ? value
      : value.left(maxLength);
  }
}
// code-analyzer-unsuppress(sfge)
