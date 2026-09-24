/**
 * Follow-up callouts that can't run in triggers or the webhook (hard rule 6, D3).
 * Carries a work list; each execution makes its callouts first, then its DML, and chains itself for the rest.
 *
 * Work items: `PROFILE` (customer name and picture → conversation), `WEBHOOK_TEST` (LINE calls our webhook →
 * OA webhook status). M6 adds invite replies, M7 content downloads.
 *
 * `without sharing` (02 §2): async follow-up of inbound processing (Automated Process) and of OA registration;
 * updates conversations and OA configurations the running user may not own.
 */
public without sharing class LineCalloutQueueable implements Queueable, Database.AllowsCallouts {
  @TestVisible
  static final String TYPE_PROFILE = 'PROFILE';
  @TestVisible
  static final String TYPE_WEBHOOK_TEST = 'WEBHOOK_TEST';

  // Stay well under 100 callouts per transaction: each item needs one call, plus one token per channel.
  @TestVisible
  static Integer itemsPerExecution = 40;
  // Queueables can't chain inside a running test; tests assert what would be chained instead.
  @TestVisible
  static List<WorkItem> lastChainedItems;

  private static final Integer NAME_LENGTH = 80;
  private static final Integer URL_LENGTH = 255;
  private static final Integer STATUS_LENGTH = 255;

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
      // 1. Callouts
      for (WorkItem item : slice) {
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
    }
    return null;
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
