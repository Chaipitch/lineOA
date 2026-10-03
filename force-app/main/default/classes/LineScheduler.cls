/**
 * The package's one scheduled job (02 §2): every night it starts the daily LINE activity sync and checks every OA's
 * credentials with LINE (DEC-33); from M10 it starts the retention batch too. Scheduled, unscheduled and run from the
 * LINE Admin page (DEC-29), because a subscriber cannot schedule a non-global class from Setup or anonymous Apex.
 *
 * `with sharing`: it reads job metadata and, in system mode, the OA list for the credentials check; the batch and
 * queueable it starts declare their own sharing.
 */
public with sharing class LineScheduler implements Schedulable {
  /** One job per org, found again by this name. */
  public static final String JOB_NAME = 'LINE Connect nightly jobs';
  private static final String CREDENTIAL_REMOVED = 'Removed';
  /** 01:00 every day, in the scheduling user's time zone (DEC-30). */
  public static final String CRON = '0 0 1 * * ?';

  /**
   * Starts tonight's work: the daily sync (unless it's off in LINE Settings) and the credentials check, which always
   * runs. Each is guarded on its own, so one failing never skips the other.
   * @param context schedulable context
   */
  public void execute(SchedulableContext context) {
    try {
      if (LineSettings.dailySyncEnabled()) {
        Database.executeBatch(
          new LineDailyEventSyncBatch(),
          LineDailyEventSyncBatch.BATCH_SIZE
        );
      }
    } catch (Exception e) {
      LineLogger.error('LineScheduler.execute', e);
    }
    try {
      checkCredentials();
    } catch (Exception e) {
      LineLogger.error('LineScheduler.checkCredentials', e);
    } finally {
      LineLogger.flush();
    }
  }

  /**
   * Queues a credentials check for every OA that still has a secret, i.e. every OA not marked *Removed* (DEC-33).
   * One queueable carries them all and chains itself; a schedulable can't make callouts itself.
   * @return the number of OAs queued
   */
  @TestVisible
  static Integer checkCredentials() {
    List<LineCalloutQueueable.WorkItem> items = new List<LineCalloutQueueable.WorkItem>();
    for (LINE_OA_Configuration__c oa : [
      SELECT Id, Channel_Id__c
      FROM LINE_OA_Configuration__c
      WHERE
        Credential_Status__c = NULL
        OR Credential_Status__c != :CREDENTIAL_REMOVED
      WITH SYSTEM_MODE
      ORDER BY Name
    ]) {
      items.add(
        LineCalloutQueueable.credentialCheckItem(oa.Id, oa.Channel_Id__c)
      );
    }
    LineCalloutQueueable.enqueue(items);
    return items.size();
  }

  /**
   * Schedules the nightly job, replacing any existing one, so the schedule can't end up duplicated.
   * @return the CronTrigger Id
   */
  public static Id schedule() {
    unschedule();
    return System.schedule(JOB_NAME, CRON, new LineScheduler());
  }

  /**
   * Removes the nightly job if it is scheduled.
   */
  public static void unschedule() {
    for (CronTrigger job : jobs()) {
      System.abortJob(job.Id);
    }
  }

  /**
   * @return the scheduled nightly job, or null when there is none
   */
  public static CronTrigger current() {
    List<CronTrigger> found = jobs();
    return found.isEmpty() ? null : found[0];
  }

  /**
   * Runs the daily sync now for today so far (07 §3 step 9). The nightly run rebuilds the same Event later with the
   * full day, so this never leaves a partial Event behind.
   * @return the batch job Id
   */
  public static Id runDailySyncNow() {
    return Database.executeBatch(
      new LineDailyEventSyncBatch(
        LineDailyEventSyncBatch.today(LineDailyEventSyncBatch.orgTimeZone())
      ),
      LineDailyEventSyncBatch.BATCH_SIZE
    );
  }

  /**
   * @return the most recent daily sync run, or null if it has never run
   */
  public static AsyncApexJob lastDailySync() {
    List<AsyncApexJob> found = [
      SELECT
        Id,
        Status,
        CompletedDate,
        CreatedDate,
        NumberOfErrors,
        JobItemsProcessed,
        TotalJobItems
      FROM AsyncApexJob
      WHERE
        JobType = 'BatchApex'
        AND ApexClass.Name = 'LineDailyEventSyncBatch'
        AND ApexClass.NamespacePrefix = :namespaceOrNull()
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
      LIMIT 1
    ];
    return found.isEmpty() ? null : found[0];
  }

  private static List<CronTrigger> jobs() {
    // Job metadata, not business data; the admin page's custom-permission check is the gate.
    return [
      SELECT Id, NextFireTime, PreviousFireTime, State
      FROM CronTrigger
      WHERE CronJobDetail.Name = :JOB_NAME
      WITH SYSTEM_MODE
    ];
  }

  // A subscriber may own a class with the same name; only ours counts.
  private static String namespaceOrNull() {
    String prefix = LineNamespace.prefix();
    return String.isEmpty(prefix) ? null : prefix;
  }
}
