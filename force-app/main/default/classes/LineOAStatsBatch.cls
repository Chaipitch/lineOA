/**
 * Per-OA numbers for reports and dashboards (DEC-49), stamped on `LINE_OA_Configuration__c` by the nightly job:
 * customers linked to a Contact (all of them, those still following, those who blocked the OA) and messages exchanged
 * (both directions, failed sends excluded).
 *
 * - Recounted from the stored records on every run, so a rerun or a missed night never makes the numbers drift.
 * - A batch over conversations rather than one aggregate query: every row an aggregate counts uses up the 50,000
 *   query-row limit, which an org's messages pass quickly. Each execute counts the messages of its own
 *   conversations, and the totals carry across executes (`Database.Stateful`).
 * - A failed execute would leave the totals short, so `finish` saves nothing when any execute failed: the previous
 *   numbers stay, and the failure is logged.
 *
 * `without sharing` (02 §2): runs as whichever admin scheduled the nightly job and must count every conversation
 * whatever that admin's sharing is, or the numbers would silently shrink. It writes counts only; nothing it reads is
 * shown to a user.
 */
public without sharing class LineOAStatsBatch implements Database.Batchable<SObject>, Database.Stateful {
  /** Conversations per execute. Their messages are counted in one aggregate, which must stay under 50,000 rows. */
  public static final Integer BATCH_SIZE = 50;

  private static final String STATUS_FOLLOWING = 'Following';
  private static final String STATUS_UNFOLLOWED = 'Unfollowed';
  private static final String STATUS_FAILED = 'Failed';

  private final Map<Id, Counts> countsByOA = new Map<Id, Counts>();
  @TestVisible
  private Boolean failed = false;

  /**
   * Every conversation of every OA.
   * @param context batch context
   * @return the conversations to count
   */
  public Database.QueryLocator start(Database.BatchableContext context) {
    return Database.getQueryLocator(
      [
        SELECT Id, LINE_OA_Configuration__c, Contact__c, Status__c
        FROM LINE_Conversation__c
        WITH SYSTEM_MODE
      ]
    );
  }

  /**
   * Adds the scope's customers and messages to each OA's totals.
   * @param context batch context
   * @param scope conversations
   */
  public void execute(
    Database.BatchableContext context,
    List<LINE_Conversation__c> scope
  ) {
    try {
      count(scope);
    } catch (Exception e) {
      failed = true;
      LineLogger.error('LineOAStatsBatch.execute', e);
    } finally {
      LineLogger.flush();
    }
  }

  /**
   * Saves the totals on every OA, including zeros for an OA with no conversations, unless an execute failed.
   * @param context batch context
   */
  public void finish(Database.BatchableContext context) {
    try {
      if (failed || hadErrors(context)) {
        LineLogger.error(
          'LineOAStatsBatch.finish',
          'Not saved: part of the count failed, so the totals would be short. The previous numbers stay.',
          null,
          null
        );
        return;
      }
      save();
    } catch (Exception e) {
      LineLogger.error('LineOAStatsBatch.finish', e);
    } finally {
      LineLogger.flush();
    }
  }

  // ---------------------------------------------------------------------------------------------------------------

  private void count(List<LINE_Conversation__c> scope) {
    for (LINE_Conversation__c c : scope) {
      if (c.Contact__c == null) {
        continue;
      }
      Counts counts = countsFor(c.LINE_OA_Configuration__c);
      counts.connected++;
      if (c.Status__c == STATUS_FOLLOWING) {
        counts.active++;
      } else if (c.Status__c == STATUS_UNFOLLOWED) {
        counts.blocked++;
      }
    }
    for (AggregateResult row : [
      SELECT LINE_Conversation__r.LINE_OA_Configuration__c oaId, COUNT(Id) n
      FROM LINE_Message__c
      WHERE LINE_Conversation__c IN :scope AND Status__c != :STATUS_FAILED
      WITH SYSTEM_MODE
      GROUP BY LINE_Conversation__r.LINE_OA_Configuration__c
    ]) {
      countsFor((Id) row.get('oaId')).messages += (Integer) row.get('n');
    }
  }

  private Counts countsFor(Id oaId) {
    Counts counts = countsByOA.get(oaId);
    if (counts == null) {
      counts = new Counts();
      countsByOA.put(oaId, counts);
    }
    return counts;
  }

  // An execute that hit a limit can't be caught, so the job's own error count is checked too.
  private static Boolean hadErrors(Database.BatchableContext context) {
    if (context == null || context.getJobId() == null) {
      return false;
    }
    for (AsyncApexJob job : [
      SELECT NumberOfErrors
      FROM AsyncApexJob
      WHERE Id = :context.getJobId()
      WITH SYSTEM_MODE
    ]) {
      return job.NumberOfErrors > 0;
    }
    return false;
  }

  private void save() {
    Datetime now = Datetime.now();
    List<LINE_OA_Configuration__c> updates = new List<LINE_OA_Configuration__c>();
    for (LINE_OA_Configuration__c oa : [
      SELECT Id
      FROM LINE_OA_Configuration__c
      WITH SYSTEM_MODE
    ]) {
      Counts counts = countsByOA.containsKey(oa.Id)
        ? countsByOA.get(oa.Id)
        : new Counts();
      updates.add(
        new LINE_OA_Configuration__c(
          Id = oa.Id,
          Connected_Customers__c = counts.connected,
          Active_Followers__c = counts.active,
          Blocked_Customers__c = counts.blocked,
          Messages_Exchanged__c = counts.messages,
          Stats_Updated_At__c = now
        )
      );
    }
    if (!updates.isEmpty()) {
      LineLogger.saveErrors(
        'LineOAStatsBatch.save',
        Database.update(updates, false, AccessLevel.SYSTEM_MODE),
        updates
      );
    }
  }

  private class Counts {
    Integer connected = 0;
    Integer active = 0;
    Integer blocked = 0;
    Integer messages = 0;
  }
}
