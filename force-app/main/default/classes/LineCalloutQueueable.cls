/**
 * Follow-up callouts that can't run in triggers or the webhook (hard rule 6, D3).
 * Carries a work list; each execution makes its callouts first, then its DML, and chains itself for the rest.
 *
 * Work items: `PROFILE` (customer name and picture → conversation), `WEBHOOK_TEST` (LINE calls our webhook →
 * OA webhook status), `CREDENTIAL_CHECK` (nightly: does LINE still accept the OA's channel ID and secret? DEC-33),
 * `INVITE_REPLY` (the free reply confirming, or refusing, a QR invite link; D10), `DOWNLOAD` (a customer's image, video,
 * audio or file → Salesforce File on the conversation and its Contact; M7).
 *
 * `without sharing` (02 §2): async follow-up of inbound processing (Automated Process) and of OA registration;
 * updates conversations and OA configurations the running user may not own.
 */
public without sharing class LineCalloutQueueable implements Queueable, Database.AllowsCallouts {
  @TestVisible
  static final String TYPE_PROFILE = 'PROFILE';
  @TestVisible
  static final String TYPE_WEBHOOK_TEST = 'WEBHOOK_TEST';
  @TestVisible
  static final String TYPE_CREDENTIAL_CHECK = 'CREDENTIAL_CHECK';
  @TestVisible
  static final String TYPE_INVITE_REPLY = 'INVITE_REPLY';
  @TestVisible
  static final String TYPE_DOWNLOAD = 'DOWNLOAD';
  // Bytes downloaded per execution before the remaining downloads move to the next one. Async heap is 12 MB, and
  // every file stays in memory until the DML phase, so one large file (up to Max_Download_Bytes__c) goes alone.
  @TestVisible
  static Long downloadBytesPerExecution = 3000000;
  // LINE transcodes video and audio before they can be fetched; we look again a minute later, a few times.
  @TestVisible
  static final Integer MAX_TRANSCODING_ATTEMPTS = 5;
  private static final Integer RETRY_DELAY_MINUTES = 1;
  @TestVisible
  static List<WorkItem> lastDelayedItems;
  /** Invite reply outcomes. */
  public static final String INVITE_LINKED = 'linked';
  public static final String INVITE_REFUSED = 'refused';
  @TestVisible
  static final String CREDENTIAL_VALID = 'Valid';
  @TestVisible
  static final String CREDENTIAL_REJECTED = 'Rejected';

  // Stay well under 100 callouts per transaction: each item needs one call, plus one token per channel.
  @TestVisible
  static Integer itemsPerExecution = 40;
  // Queueables can't chain inside a running test; tests assert what would be chained instead.
  @TestVisible
  static List<WorkItem> lastChainedItems;

  private static final Integer NAME_LENGTH = 80;
  private static String orgLanguage;
  private static final Integer URL_LENGTH = 255;
  private static final Integer STATUS_LENGTH = 255;
  private static final Integer TITLE_LENGTH = 255;

  private final List<WorkItem> items;

  /** One unit of work. Holds no secrets: the secret is read from LineCredentialStore when needed. */
  public class WorkItem {
    public String type;
    public Id recordId;
    public Id oaConfigId;
    public String channelId;
    public String lineUserId;
    // PROFILE only: the customer has sent a message, so the conversation may gain a Contact (03 §5).
    public Boolean resolveContact;
    // INVITE_REPLY only: LINE's single-use reply token (not a credential) and the outcome to tell the customer.
    public String replyToken;
    public String inviteOutcome;
    // DOWNLOAD only. recordId is the LINE_Message__c.
    public Id conversationId;
    public String lineMessageId;
    public String messageType;
    public String fileName;
    public Integer attempts = 0;
  }

  // A downloaded file waiting for the DML phase.
  private class PendingFile {
    WorkItem item;
    Blob body;
    String contentType;
  }

  /**
   * @param messageId the stored inbound message
   * @param conversationId its conversation (the file's first location)
   * @param oaConfigId the conversation's OA
   * @param channelId the OA's channel ID
   * @param lineMessageId LINE's message ID, used to fetch the content
   * @param messageType image, video, audio or file
   * @param fileName the customer's file name, for files
   * @return a download work item (M7)
   */
  public static WorkItem downloadItem(
    Id messageId,
    Id conversationId,
    Id oaConfigId,
    String channelId,
    String lineMessageId,
    String messageType,
    String fileName
  ) {
    WorkItem item = new WorkItem();
    item.type = TYPE_DOWNLOAD;
    item.recordId = messageId;
    item.conversationId = conversationId;
    item.oaConfigId = oaConfigId;
    item.channelId = channelId;
    item.lineMessageId = lineMessageId;
    item.messageType = messageType;
    item.fileName = fileName;
    return item;
  }

  /**
   * @param conversationId the conversation the invite code arrived in
   * @param oaConfigId the conversation's OA
   * @param channelId the OA's channel ID
   * @param replyToken the event's reply token
   * @param outcome `INVITE_LINKED` or `INVITE_REFUSED`
   * @return an invite-reply work item (D10: a free reply, never a paid push)
   */
  public static WorkItem inviteReplyItem(
    Id conversationId,
    Id oaConfigId,
    String channelId,
    String replyToken,
    String outcome
  ) {
    WorkItem item = new WorkItem();
    item.type = TYPE_INVITE_REPLY;
    item.recordId = conversationId;
    item.oaConfigId = oaConfigId;
    item.channelId = channelId;
    item.replyToken = replyToken;
    item.inviteOutcome = outcome;
    return item;
  }

  /**
   * @param items the work list
   */
  public LineCalloutQueueable(List<WorkItem> items) {
    this.items = items == null ? new List<WorkItem>() : items;
  }

  /**
   * @param conversationId conversation to update
   * @param oaConfigId the conversation's OA
   * @param channelId the OA's channel ID
   * @param lineUserId the customer's LINE user ID
   * @return a profile work item
   */
  public static WorkItem profileItem(
    Id conversationId,
    Id oaConfigId,
    String channelId,
    String lineUserId
  ) {
    return profileItem(
      conversationId,
      oaConfigId,
      channelId,
      lineUserId,
      false
    );
  }

  /**
   * @param conversationId conversation to update
   * @param oaConfigId the conversation's OA
   * @param channelId the OA's channel ID
   * @param lineUserId the customer's LINE user ID
   * @param resolveContact whether to link or create a Contact for this conversation (03 §5)
   * @return a profile work item
   */
  public static WorkItem profileItem(
    Id conversationId,
    Id oaConfigId,
    String channelId,
    String lineUserId,
    Boolean resolveContact
  ) {
    WorkItem item = new WorkItem();
    item.type = TYPE_PROFILE;
    item.recordId = conversationId;
    item.oaConfigId = oaConfigId;
    item.channelId = channelId;
    item.lineUserId = lineUserId;
    item.resolveContact = resolveContact;
    return item;
  }

  /**
   * @param oaConfigId the OA whose webhook LINE should call
   * @param channelId the OA's channel ID
   * @return a webhook-test work item
   */
  public static WorkItem webhookTestItem(Id oaConfigId, String channelId) {
    WorkItem item = new WorkItem();
    item.type = TYPE_WEBHOOK_TEST;
    item.recordId = oaConfigId;
    item.oaConfigId = oaConfigId;
    item.channelId = channelId;
    return item;
  }

  /**
   * @param oaConfigId the OA whose credentials to check
   * @param channelId the OA's channel ID
   * @return a credentials-check work item (DEC-33)
   */
  public static WorkItem credentialCheckItem(Id oaConfigId, String channelId) {
    WorkItem item = new WorkItem();
    item.type = TYPE_CREDENTIAL_CHECK;
    item.recordId = oaConfigId;
    item.oaConfigId = oaConfigId;
    item.channelId = channelId;
    return item;
  }

  /**
   * Enqueues one job for the whole list (callers enqueue at most once per transaction).
   * @param items work items
   * @return the job Id, or null if there was nothing to do or the queue limit was reached (logged)
   */
  public static Id enqueue(List<WorkItem> items) {
    if (items == null || items.isEmpty()) {
      return null;
    }
    if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
      LineLogger.error(
        'LineCalloutQueueable.enqueue',
        'Queueable limit reached; follow-up callouts skipped.',
        null,
        null
      );
      return null;
    }
    return System.enqueueJob(new LineCalloutQueueable(items));
  }

  /**
   * Runs a slice of the work list, then chains itself for the remainder.
   * @param context queueable context
   */
  public void execute(QueueableContext context) {
    List<WorkItem> slice = new List<WorkItem>();
    List<WorkItem> rest = new List<WorkItem>();
    for (WorkItem item : items) {
      (slice.size() < itemsPerExecution ? slice : rest).add(item);
    }
    try {
      List<SObject> updates = new List<SObject>();
      Map<Id, LINE_Conversation__c> conversationUpdates = new Map<Id, LINE_Conversation__c>();
      Set<Id> resolveContactIds = new Set<Id>();
      List<PendingFile> files = new List<PendingFile>();
      List<WorkItem> later = new List<WorkItem>();
      Long downloadedBytes = 0;
      // 1. Callouts
      for (WorkItem item : slice) {
        if (item.type == TYPE_DOWNLOAD) {
          if (downloadedBytes >= downloadBytesPerExecution) {
            rest.add(item);
            continue;
          }
          downloadedBytes += download(item, files, later, updates);
          continue;
        }
        SObject change = run(item);
        if (item.type == TYPE_PROFILE) {
          if (item.resolveContact == true) {
            resolveContactIds.add(item.recordId);
          }
          if (change != null) {
            conversationUpdates.put(
              item.recordId,
              (LINE_Conversation__c) change
            );
          }
        } else if (change != null) {
          updates.add(change);
        }
      }
      // 2. Linking (queries and DML only, so it stays after every callout)
      linkContacts(resolveContactIds, conversationUpdates);
      updates.addAll(conversationUpdates.values());
      saveFiles(files, updates, conversationUpdates);
      // 3. DML
      if (!updates.isEmpty()) {
        // Group by type: a mixed list may have at most 10 type chunks.
        updates.sort();
        List<Database.SaveResult> results = Database.update(
          updates,
          false,
          AccessLevel.SYSTEM_MODE
        );
        LineLogger.saveErrors('LineCalloutQueueable.execute', results, updates);
      }
      chain(rest);
      chainLater(later);
    } catch (Exception e) {
      LineLogger.error('LineCalloutQueueable.execute', e);
    } finally {
      LineLogger.flush();
    }
  }

  /**
   * Gives each conversation a Contact where one can be found or created, merging the result into the conversation
   * updates so every conversation is still updated exactly once.
   */
  private static void linkContacts(
    Set<Id> conversationIds,
    Map<Id, LINE_Conversation__c> conversationUpdates
  ) {
    if (conversationIds.isEmpty()) {
      return;
    }
    Map<Id, String> displayNames = new Map<Id, String>();
    for (Id conversationId : conversationIds) {
      LINE_Conversation__c pending = conversationUpdates.get(conversationId);
      if (pending != null && String.isNotBlank(pending.Name)) {
        displayNames.put(conversationId, pending.Name);
      }
    }
    Map<Id, Id> contactIds = LineLinkService.resolveContacts(
      conversationIds,
      displayNames
    );
    for (Id conversationId : contactIds.keySet()) {
      LINE_Conversation__c pending = conversationUpdates.get(conversationId);
      if (pending == null) {
        pending = new LINE_Conversation__c(Id = conversationId);
        conversationUpdates.put(conversationId, pending);
      }
      pending.Contact__c = contactIds.get(conversationId);
    }
  }

  // Returns the record change for one item, or null. Item failures are logged and don't stop the others.
  private SObject run(WorkItem item) {
    try {
      if (item.type == TYPE_PROFILE) {
        return fetchProfile(item);
      }
      if (item.type == TYPE_WEBHOOK_TEST) {
        return testWebhook(item);
      }
      if (item.type == TYPE_CREDENTIAL_CHECK) {
        // Issuing a token is the cheapest call that proves LINE still accepts the ID and secret.
        LineApiClient.forChannel(item.channelId).issueToken();
        return credentialStatus(item.recordId, CREDENTIAL_VALID);
      }
      if (item.type == TYPE_INVITE_REPLY) {
        // An expired reply token fails here and is only logged: we never fall back to a paid push (D10).
        LineApiClient.forChannel(item.channelId)
          .reply(
            item.replyToken,
            new List<LineApiModels.Message>{
              LineApiModels.textMessage(inviteReplyText(item.inviteOutcome))
            }
          );
        return null;
      }
      LineLogger.error(
        'LineCalloutQueueable.run',
        'Unknown work item type: ' + item.type,
        item.oaConfigId,
        item.recordId
      );
    } catch (LineApiException e) {
      LineLogger.error(
        'LineCalloutQueueable.' + item.type,
        e,
        item.oaConfigId,
        item.recordId
      );
      if (item.type == TYPE_WEBHOOK_TEST) {
        return webhookStatus(item.recordId, 'Failed: ' + e.getMessage());
      }
      // Only a definite "no" from LINE flags the OA. A timeout or a LINE outage leaves the status as it was.
      if (item.type == TYPE_CREDENTIAL_CHECK && e.isCredentialError()) {
        return credentialStatus(item.recordId, CREDENTIAL_REJECTED);
      }
    }
    return null;
  }

  // The customer reads this, not a Salesforce user, so it uses the org's default language rather than the running
  // user's (Automated Process).
  @TestVisible
  private static String inviteReplyText(String outcome) {
    String labelName = outcome == INVITE_LINKED
      ? 'LINE_Invite_Reply_Linked'
      : 'LINE_Invite_Reply_Refused';
    String fallback = outcome == INVITE_LINKED
      ? System.Label.LINE_Invite_Reply_Linked
      : System.Label.LINE_Invite_Reply_Refused;
    try {
      if (orgLanguage == null) {
        orgLanguage = [
          SELECT LanguageLocaleKey
          FROM Organization
          WITH SYSTEM_MODE
          LIMIT 1
        ]
        .LanguageLocaleKey;
      }
      String language = orgLanguage;
      if (
        System.Label.translationExists(
          LineNamespace.prefix(),
          labelName,
          language
        )
      ) {
        return System.Label.get(LineNamespace.prefix(), labelName, language);
      }
    } catch (Exception e) {
      return fallback;
    }
    return fallback;
  }

  private static LINE_OA_Configuration__c credentialStatus(
    Id oaConfigId,
    String status
  ) {
    return new LINE_OA_Configuration__c(
      Id = oaConfigId,
      Credential_Status__c = status,
      Credential_Checked_At__c = Datetime.now()
    );
  }

  private SObject fetchProfile(WorkItem item) {
    LineApiModels.Profile profile = LineApiClient.forChannel(item.channelId)
      .getProfile(item.lineUserId);
    if (profile == null) {
      return null;
    }
    LINE_Conversation__c c = new LINE_Conversation__c(Id = item.recordId);
    if (String.isNotBlank(profile.displayName)) {
      c.Name = profile.displayName.left(NAME_LENGTH);
    }
    c.Picture_Url__c = profile.pictureUrl != null &&
      profile.pictureUrl.length() <= URL_LENGTH
      ? profile.pictureUrl
      : null;
    return c;
  }

  private SObject testWebhook(WorkItem item) {
    // Null endpoint = test the URL registered with LINE.
    LineApiModels.WebhookTestResult result = LineApiClient.forChannel(
        item.channelId
      )
      .testWebhookEndpoint(null);
    String status = result == null
      ? 'Failed: no result'
      : (result.success == true ? 'OK' : 'Failed') +
        ' (' +
        result.statusCode +
        ' ' +
        result.reason +
        ')';
    return webhookStatus(item.recordId, status);
  }

  private static LINE_OA_Configuration__c webhookStatus(
    Id oaConfigId,
    String status
  ) {
    return new LINE_OA_Configuration__c(
      Id = oaConfigId,
      Webhook_Status__c = status.left(STATUS_LENGTH),
      Last_Verified_At__c = Datetime.now()
    );
  }

  // ---------- downloads (M7) ----------

  // Fetches one item's content. Returns the bytes now held in memory; failures become message updates.
  private static Long download(
    WorkItem item,
    List<PendingFile> files,
    List<WorkItem> later,
    List<SObject> updates
  ) {
    try {
      LineApiClient client = LineApiClient.forChannel(item.channelId);
      if (item.messageType == 'video' || item.messageType == 'audio') {
        String transcoding = client.getContentTranscodingStatus(
          item.lineMessageId
        );
        if (transcoding == 'processing') {
          if (item.attempts + 1 < MAX_TRANSCODING_ATTEMPTS) {
            item.attempts++;
            later.add(item);
          } else {
            updates.add(
              messageStatus(
                item.recordId,
                'Download Failed',
                'LINE is still processing the media.'
              )
            );
          }
          return 0;
        }
        if (transcoding == 'failed') {
          updates.add(
            messageStatus(
              item.recordId,
              'Download Failed',
              'LINE could not process the media.'
            )
          );
          return 0;
        }
      }
      LineApiModels.Content content = client.getContent(item.lineMessageId);
      if (content.contentLength > LineSettings.maxDownloadBytes()) {
        updates.add(messageStatus(item.recordId, 'Too Large', null));
        return 0;
      }
      PendingFile file = new PendingFile();
      file.item = item;
      file.body = content.body;
      file.contentType = content.contentType;
      files.add(file);
      return content.contentLength;
    } catch (LineApiException e) {
      LineLogger.error(
        'LineCalloutQueueable.DOWNLOAD',
        e,
        item.oaConfigId,
        item.recordId
      );
      updates.add(
        messageStatus(item.recordId, 'Download Failed', e.userMessage())
      );
      return 0;
    }
  }

  // Saves downloaded content as Files on the conversation (and its Contact), then marks the messages received.
  private static void saveFiles(
    List<PendingFile> files,
    List<SObject> updates,
    Map<Id, LINE_Conversation__c> conversationUpdates
  ) {
    if (files.isEmpty()) {
      return;
    }
    List<ContentVersion> versions = new List<ContentVersion>();
    for (PendingFile f : files) {
      String title = fileTitle(f);
      versions.add(
        new ContentVersion(
          Title = title,
          PathOnClient = title.contains('.')
            ? title
            : title + extensionFor(f.contentType),
          VersionData = f.body,
          FirstPublishLocationId = f.item.conversationId
        )
      );
    }
    List<Database.SaveResult> results = Database.insert(
      versions,
      false,
      AccessLevel.SYSTEM_MODE
    );
    Set<Id> savedIds = new Set<Id>();
    for (Integer i = 0; i < results.size(); i++) {
      // Release the bytes as soon as Salesforce has them.
      versions[i].VersionData = null;
      files[i].body = null;
      if (results[i].isSuccess()) {
        savedIds.add(results[i].getId());
      } else {
        String error = results[i].getErrors()[0].getMessage();
        LineLogger.error(
          'LineCalloutQueueable.saveFiles',
          error,
          files[i].item.oaConfigId,
          files[i].item.recordId
        );
        updates.add(
          messageStatus(files[i].item.recordId, 'Download Failed', error)
        );
      }
    }
    if (savedIds.isEmpty()) {
      return;
    }
    Map<Id, ContentVersion> saved = new Map<Id, ContentVersion>(
      [
        SELECT Id, ContentDocumentId, ContentSize, Title
        FROM ContentVersion
        WHERE Id IN :savedIds
        WITH SYSTEM_MODE
      ]
    );
    Set<Id> conversationIds = new Set<Id>();
    for (PendingFile f : files) {
      conversationIds.add(f.item.conversationId);
    }
    Map<Id, LINE_Conversation__c> conversations = new Map<Id, LINE_Conversation__c>(
      [
        SELECT Id, Contact__c
        FROM LINE_Conversation__c
        WHERE Id IN :conversationIds
        WITH SYSTEM_MODE
      ]
    );
    List<ContentDocumentLink> contactLinks = new List<ContentDocumentLink>();
    for (Integer i = 0; i < versions.size(); i++) {
      ContentVersion v = saved.get(results[i].getId());
      if (v == null) {
        continue;
      }
      WorkItem item = files[i].item;
      LINE_Message__c m = messageStatus(item.recordId, 'Received', null);
      m.Content_Document_Id__c = v.ContentDocumentId;
      m.File_Size__c = v.ContentSize;
      m.File_Name__c = String.isBlank(item.fileName)
        ? versions[i].PathOnClient
        : item.fileName;
      updates.add(m);
      // A Contact linked or created earlier in this same execution isn't saved yet.
      LINE_Conversation__c pending = conversationUpdates.get(
        item.conversationId
      );
      Id contactId = pending?.Contact__c != null
        ? pending.Contact__c
        : conversations.get(item.conversationId)?.Contact__c;
      if (contactId != null) {
        // The customer's files also appear on their Contact.
        contactLinks.add(
          new ContentDocumentLink(
            LinkedEntityId = contactId,
            ContentDocumentId = v.ContentDocumentId,
            ShareType = 'V',
            Visibility = 'AllUsers'
          )
        );
      }
    }
    if (!contactLinks.isEmpty()) {
      LineLogger.saveErrors(
        'LineCalloutQueueable.contactLinks',
        Database.insert(contactLinks, false, AccessLevel.SYSTEM_MODE),
        contactLinks
      );
    }
  }

  private static String fileTitle(PendingFile f) {
    if (String.isNotBlank(f.item.fileName)) {
      return f.item.fileName.left(TITLE_LENGTH);
    }
    return ('LINE ' +
      f.item.messageType +
      ' ' +
      f.item.lineMessageId)
      .left(TITLE_LENGTH);
  }

  @TestVisible
  private static String extensionFor(String contentType) {
    String type = contentType == null
      ? ''
      : contentType.substringBefore(';').trim().toLowerCase();
    switch on type {
      when 'image/jpeg' {
        return '.jpg';
      }
      when 'image/png' {
        return '.png';
      }
      when 'image/gif' {
        return '.gif';
      }
      when 'video/mp4' {
        return '.mp4';
      }
      when 'audio/x-m4a', 'audio/m4a', 'audio/mp4' {
        return '.m4a';
      }
      when else {
        return '.bin';
      }
    }
  }

  private static LINE_Message__c messageStatus(
    Id messageId,
    String status,
    String error
  ) {
    return new LINE_Message__c(
      Id = messageId,
      Status__c = status,
      Error__c = error == null ? null : error.left(STATUS_LENGTH)
    );
  }

  // Video and audio still being transcoded by LINE: look again after a delay rather than spinning.
  private static void chainLater(List<WorkItem> later) {
    if (later.isEmpty()) {
      return;
    }
    if (Test.isRunningTest()) {
      lastDelayedItems = later;
      return;
    }
    System.enqueueJob(new LineCalloutQueueable(later), RETRY_DELAY_MINUTES);
  }

  private static void chain(List<WorkItem> rest) {
    if (rest.isEmpty()) {
      return;
    }
    if (Test.isRunningTest()) {
      lastChainedItems = rest;
      return;
    }
    System.enqueueJob(new LineCalloutQueueable(rest));
  }
}
