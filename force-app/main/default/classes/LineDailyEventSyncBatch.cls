/**
 * Daily LINE activity sync (01 F8, 03 §3 Event, M9): one Event per conversation per day, carrying that day's
 * transcript, so LINE conversations appear in standard Activity History.
 *
 * - A "day" is midnight to midnight in the org's default time zone (DEC-30). The default target is yesterday.
 * - Event shape follows the TA review document §2.8 (DEC-28): Who = Contact, What = the Contact's Account,
 *   `LINE_Conversation__c` = the conversation.
 * - Idempotent: an existing Event is found by `LINE_Sync_Key__c` and **rebuilt** from the stored messages, so a rerun
 *   never duplicates and also repairs a day that was synced before its last message arrived.
 * - Event DML is partial-success and logged (hard rule 7): a subscriber validation rule on Event skips that one
 *   conversation, never the batch.
 *
 * `without sharing` (02 §2, DEC-30): runs as whichever admin scheduled it, possibly for years, and must see every
 * conversation regardless of that admin's sharing, or the sync would silently shrink. Nothing it reads reaches a user.
 */
public without sharing class LineDailyEventSyncBatch implements Database.Batchable<SObject> {
  /** Conversations per execute. Each can carry a day of messages, so this stays well below 200 for heap. */
  public static final Integer BATCH_SIZE = 20;

  @TestVisible
  static final Integer DESCRIPTION_LENGTH = 32000;
  private static final Integer SUBJECT_LENGTH = 255;
  private static final String STATUS_FREE = 'Free';
  private static final Long MINUTE_MS = 60000;

  private static TimeZone cachedOrgZone;

  private final Date targetDay;
  private final Datetime dayStart;
  private final Datetime dayEnd;

  /** Syncs yesterday (org time zone). */
  public LineDailyEventSyncBatch() {
    this(null);
  }

  /**
   * @param targetDay the calendar day to sync, in the org's time zone; null = yesterday
   */
  public LineDailyEventSyncBatch(Date targetDay) {
    TimeZone orgZone = orgTimeZone();
    this.targetDay = targetDay == null ? today(orgZone).addDays(-1) : targetDay;
    this.dayStart = startOfDay(this.targetDay, orgZone);
    this.dayEnd = startOfDay(this.targetDay.addDays(1), orgZone);
  }

  /**
   * Conversations with a Contact that have had a message since the start of the day. Some of them only had messages
   * after the day ended; `execute` skips those.
   * @param context batch context
   * @return the conversations to consider
   */
  public Database.QueryLocator start(Database.BatchableContext context) {
    // The setting is checked here as well as in the scheduler, so a manual run honours it too.
    Integer rowLimit = LineSettings.dailySyncEnabled() ? 50000000 : 0;
    return Database.getQueryLocator(
      [
        SELECT
          Id,
          OwnerId,
          Contact__c,
          Contact__r.Name,
          Contact__r.AccountId,
          LINE_OA_Configuration__r.Name
        FROM LINE_Conversation__c
        WHERE Contact__c != NULL AND Last_Message_At__c >= :dayStart
        WITH SYSTEM_MODE
        LIMIT :rowLimit
      ]
    );
  }

  /**
   * Builds, then inserts or rebuilds, the Event of each conversation in the scope.
   * @param context batch context
   * @param scope conversations
   */
  public void execute(
    Database.BatchableContext context,
    List<LINE_Conversation__c> scope
  ) {
    try {
      sync(scope);
    } catch (Exception e) {
      LineLogger.error('LineDailyEventSyncBatch.execute', e);
    } finally {
      LineLogger.flush();
    }
  }

  /**
   * Nothing to finish: each execute flushes its own log entries.
   * @param context batch context
   */
  public void finish(Database.BatchableContext context) {
    return;
  }

  // ---------------------------------------------------------------------------------------------------------------

  private void sync(List<LINE_Conversation__c> scope) {
    Map<Id, LINE_Conversation__c> conversations = new Map<Id, LINE_Conversation__c>(
      scope
    );
    Map<Id, Transcript> transcripts = transcriptsFor(conversations);
    if (transcripts.isEmpty()) {
      return;
    }

    Map<String, Id> existingByKey = existingEvents(transcripts.keySet());
    List<Event> toInsert = new List<Event>();
    List<Event> toUpdate = new List<Event>();
    for (Id conversationId : transcripts.keySet()) {
      Event e = buildEvent(
        conversations.get(conversationId),
        transcripts.get(conversationId)
      );
      Id existingId = existingByKey.get(e.LINE_Sync_Key__c);
      if (existingId == null) {
        toInsert.add(e);
      } else {
        e.Id = existingId;
        toUpdate.add(e);
      }
    }
    if (!toInsert.isEmpty()) {
      LineLogger.saveErrors(
        'LineDailyEventSyncBatch.insert',
        Database.insert(toInsert, false, AccessLevel.SYSTEM_MODE),
        toInsert
      );
    }
    if (!toUpdate.isEmpty()) {
      LineLogger.saveErrors(
        'LineDailyEventSyncBatch.update',
        Database.update(toUpdate, false, AccessLevel.SYSTEM_MODE),
        toUpdate
      );
    }
  }

  // One transcript per conversation that had at least one message inside the day.
  private Map<Id, Transcript> transcriptsFor(
    Map<Id, LINE_Conversation__c> conversations
  ) {
    Map<Id, String> zoneByOwner = ownerTimeZones(conversations.values());
    String orgZoneId = orgTimeZone().getID();
    Map<Id, Transcript> result = new Map<Id, Transcript>();
    Set<Id> conversationIds = conversations.keySet();
    // A SOQL for-loop streams the rows in chunks, so a busy day doesn't have to fit in the heap at once.
    for (LINE_Message__c m : [
      SELECT
        LINE_Conversation__c,
        Direction__c,
        Message_Type__c,
        Text__c,
        File_Name__c,
        Location__c,
        Sent_At__c,
        Sender__r.FirstName,
        Sender__r.Name
      FROM LINE_Message__c
      WHERE
        LINE_Conversation__c IN :conversationIds
        AND Sent_At__c >= :dayStart
        AND Sent_At__c < :dayEnd
      WITH SYSTEM_MODE
      ORDER BY LINE_Conversation__c, Sent_At__c, Id
    ]) {
      Transcript t = result.get(m.LINE_Conversation__c);
      if (t == null) {
        LINE_Conversation__c c = conversations.get(m.LINE_Conversation__c);
        String zoneId = zoneByOwner.get(c.OwnerId);
        t = new Transcript(zoneId == null ? orgZoneId : zoneId);
        result.put(m.LINE_Conversation__c, t);
      }
      t.add(m);
    }
    return result;
  }

  // Transcript times are shown in the Event owner's time zone (03 §3); queue-owned conversations use the org's.
  private static Map<Id, String> ownerTimeZones(
    List<LINE_Conversation__c> conversations
  ) {
    Set<Id> userIds = new Set<Id>();
    for (LINE_Conversation__c c : conversations) {
      if (c.OwnerId.getSObjectType() == User.SObjectType) {
        userIds.add(c.OwnerId);
      }
    }
    Map<Id, String> result = new Map<Id, String>();
    for (User u : [
      SELECT Id, TimeZoneSidKey
      FROM User
      WHERE Id IN :userIds
      WITH SYSTEM_MODE
    ]) {
      result.put(u.Id, u.TimeZoneSidKey);
    }
    return result;
  }

  private Map<String, Id> existingEvents(Set<Id> conversationIds) {
    Set<String> keys = new Set<String>();
    for (Id conversationId : conversationIds) {
      keys.add(syncKey(conversationId));
    }
    Map<String, Id> result = new Map<String, Id>();
    // Filtered on the lookup as well, which is indexed; the sync key alone is not.
    for (Event e : [
      SELECT Id, LINE_Sync_Key__c
      FROM Event
      WHERE
        LINE_Conversation__c IN :conversationIds
        AND LINE_Sync_Key__c IN :keys
      WITH SYSTEM_MODE
    ]) {
      result.put(e.LINE_Sync_Key__c, e.Id);
    }
    return result;
  }

  private Event buildEvent(LINE_Conversation__c c, Transcript t) {
    Event e = new Event(
      Subject = String.format(
          System.Label.LINE_Event_Subject,
          new List<Object>{ c.Contact__r.Name, c.LINE_OA_Configuration__r.Name }
        )
        .left(SUBJECT_LENGTH),
      WhoId = c.Contact__c,
      WhatId = c.Contact__r.AccountId,
      LINE_Conversation__c = c.Id,
      // Salesforce keeps an Event's length in whole minutes and recomputes the end from the start, dropping seconds;
      // rounding outwards keeps every message of the day inside the Event.
      StartDateTime = floorToMinute(t.firstAt),
      EndDateTime = ceilToMinute(t.lastAt),
      Description = t.text(),
      ShowAs = STATUS_FREE,
      LINE_Sync_Key__c = syncKey(c.Id)
    );
    // Events can only be owned by users; a queue-owned conversation leaves the running user as owner.
    if (c.OwnerId.getSObjectType() == User.SObjectType) {
      e.OwnerId = c.OwnerId;
    }
    return e;
  }

  @TestVisible
  private String syncKey(Id conversationId) {
    return conversationId +
      ':' +
      Datetime.newInstanceGmt(targetDay, Time.newInstance(0, 0, 0, 0))
        .formatGmt('yyyy-MM-dd');
  }

  // ---------------------------------------------------------------------------------------------------------------

  /** One conversation's day, as transcript lines. */
  private class Transcript {
    private final String timeZoneSid;
    private final List<String> lines = new List<String>();
    private Integer length = 0;
    private Boolean truncated = false;
    Datetime firstAt;
    Datetime lastAt;

    Transcript(String timeZoneSid) {
      this.timeZoneSid = timeZoneSid;
    }

    void add(LINE_Message__c m) {
      if (firstAt == null) {
        firstAt = m.Sent_At__c;
      }
      lastAt = m.Sent_At__c;
      if (truncated) {
        return;
      }
      String line =
        m.Sent_At__c.format('HH:mm', timeZoneSid) +
        ' ' +
        speaker(m) +
        ': ' +
        body(m);
      // Keep room for the "continued" marker, so the result never exceeds the field.
      Integer room =
        DESCRIPTION_LENGTH -
        System.Label.LINE_Event_Truncated.length() -
        1;
      if (length + line.length() + 1 > room) {
        truncated = true;
        return;
      }
      lines.add(line);
      length += line.length() + 1;
    }

    String text() {
      List<String> all = new List<String>(lines);
      if (truncated) {
        all.add(System.Label.LINE_Event_Truncated);
      }
      return String.join(all, '\n');
    }
  }

  private static String speaker(LINE_Message__c m) {
    if (m.Direction__c != 'Outbound') {
      return System.Label.LINE_Event_Customer;
    }
    // The rep's first name, as in 2.8's example ("10:03 May: …"); users without one fall back to the full name.
    if (m.Sender__r != null) {
      return String.isNotBlank(m.Sender__r.FirstName)
        ? m.Sender__r.FirstName
        : m.Sender__r.Name;
    }
    return System.Label.LINE_App_Name;
  }

  // The same placeholders as the chat panel's previews, so a transcript reads like the chat.
  @TestVisible
  private static String body(LINE_Message__c m) {
    switch on m.Message_Type__c {
      when 'text' {
        return m.Text__c == null ? '' : m.Text__c.replace('\r', '');
      }
      when 'image' {
        return System.Label.LINE_Preview_Image;
      }
      when 'video' {
        return System.Label.LINE_Preview_Video;
      }
      when 'audio' {
        return System.Label.LINE_Preview_Audio;
      }
      when 'file' {
        return String.format(
          System.Label.LINE_Preview_File,
          new List<Object>{ m.File_Name__c == null ? '' : m.File_Name__c }
        );
      }
      when 'sticker' {
        return System.Label.LINE_Preview_Sticker;
      }
      when 'location' {
        return String.format(
          System.Label.LINE_Preview_Location,
          new List<Object>{ m.Location__c == null ? '' : m.Location__c }
        );
      }
      when else {
        return System.Label.LINE_Preview_Unsupported;
      }
    }
  }

  // ---------------------------------------------------------------------------------------------------------------

  /**
   * @param value an instant
   * @return the start of its minute
   */
  @TestVisible
  static Datetime floorToMinute(Datetime value) {
    Long ms = value.getTime();
    return Datetime.newInstance(ms - Math.mod(ms, MINUTE_MS));
  }

  /**
   * @param value an instant
   * @return the instant itself on a whole minute, otherwise the start of the next minute
   */
  @TestVisible
  static Datetime ceilToMinute(Datetime value) {
    Long ms = value.getTime();
    Long rest = Math.mod(ms, MINUTE_MS);
    return rest == 0 ? value : Datetime.newInstance(ms - rest + MINUTE_MS);
  }

  /**
   * @return the org's default time zone (Setup → Company Information), which defines a "day" (DEC-30)
   */
  public static TimeZone orgTimeZone() {
    // Cached for the transaction: callers may ask once per record.
    if (cachedOrgZone == null) {
      cachedOrgZone = TimeZone.getTimeZone(
        [SELECT TimeZoneSidKey FROM Organization WITH SYSTEM_MODE LIMIT 1]
        .TimeZoneSidKey
      );
    }
    return cachedOrgZone;
  }

  /**
   * @param zone a time zone
   * @return today's date in that time zone
   */
  public static Date today(TimeZone zone) {
    return Date.valueOf(Datetime.now().format('yyyy-MM-dd', zone.getID()));
  }

  /**
   * @param day a calendar day
   * @param zone the time zone the day is in
   * @return the instant that day starts (00:00 local)
   */
  @TestVisible
  static Datetime startOfDay(Date day, TimeZone zone) {
    Datetime utcMidnight = Datetime.newInstanceGmt(
      day,
      Time.newInstance(0, 0, 0, 0)
    );
    Integer offsetMs = zone.getOffset(utcMidnight);
    Datetime guess = utcMidnight.addSeconds(-offsetMs / 1000);
    // Across a daylight-saving change the offset at local midnight differs from the one at UTC midnight.
    Integer actualMs = zone.getOffset(guess);
    return actualMs == offsetMs
      ? guess
      : utcMidnight.addSeconds(-actualMs / 1000);
  }
}
