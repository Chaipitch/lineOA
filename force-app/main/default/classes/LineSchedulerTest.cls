@IsTest
private class LineSchedulerTest {
  private static Integer scheduledJobs() {
    return [
      SELECT COUNT()
      FROM CronTrigger
      WHERE CronJobDetail.Name = :LineScheduler.JOB_NAME
    ];
  }

  private static Integer syncRuns() {
    return [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE JobType = 'BatchApex' AND ApexClass.Name = 'LineDailyEventSyncBatch'
    ];
  }

  @IsTest
  static void scheduleCreatesExactlyOneNightlyJob() {
    LineTestFactory.ensurePackageAccess();
    Test.startTest();
    LineScheduler.schedule();
    LineScheduler.schedule();
    Test.stopTest();

    Assert.areEqual(
      1,
      scheduledJobs(),
      'Scheduling twice replaces, not duplicates'
    );
    CronTrigger job = LineScheduler.current();
    Assert.isNotNull(job.NextFireTime);
    Assert.areEqual(1, job.NextFireTime.hour(), 'Runs at 01:00');
  }

  @IsTest
  static void unscheduleRemovesTheJob() {
    LineTestFactory.ensurePackageAccess();
    Test.startTest();
    LineScheduler.schedule();
    LineScheduler.unschedule();
    Test.stopTest();

    Assert.areEqual(0, scheduledJobs());
    Assert.isNull(LineScheduler.current());
  }

  @IsTest
  static void nightlyRunStartsTheDailySync() {
    LineTestFactory.ensurePackageAccess();
    Test.startTest();
    new LineScheduler().execute(null);
    Test.stopTest();

    Assert.areEqual(1, syncRuns());
    Assert.isNotNull(LineScheduler.lastDailySync());
  }

  @IsTest
  static void nightlyRunDoesNothingWhileDailySyncIsOff() {
    LineTestFactory.ensurePackageAccess();
    insert as system new LINE_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Daily_Sync_Enabled__c = false
    );
    Test.startTest();
    new LineScheduler().execute(null);
    Test.stopTest();

    Assert.areEqual(0, syncRuns());
    Assert.isNull(LineScheduler.lastDailySync(), 'Never run');
  }

  @IsTest
  static void runNowSyncsToday() {
    LineTestFactory.ensurePackageAccess();
    User rep = LineTestFactory.createUser(new List<String>{ 'LINE_Chat_User' });
    LINE_OA_Configuration__c oa = LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      rep.Id
    );
    Contact somchai = new Contact(LastName = 'Somchai');
    insert as system somchai;
    LINE_Conversation__c c = new LINE_Conversation__c(
      Name = 'Somchai',
      LINE_OA_Configuration__c = oa.Id,
      LINE_User_Id__c = 'Ucustomer1',
      Unique_Key__c = LineTestFactory.CHANNEL_A + ':Ucustomer1',
      Contact__c = somchai.Id,
      OwnerId = rep.Id,
      Last_Message_At__c = Datetime.now()
    );
    insert as system c;
    insert as system new LINE_Message__c(
      LINE_Conversation__c = c.Id,
      Direction__c = 'Inbound',
      Message_Type__c = 'text',
      Text__c = 'hello',
      Status__c = 'Received',
      Sent_At__c = Datetime.now()
    );

    Test.startTest();
    LineScheduler.runDailySyncNow();
    Test.stopTest();

    Event e = [
      SELECT LINE_Sync_Key__c
      FROM Event
      WHERE LINE_Conversation__c = :c.Id
      WITH SYSTEM_MODE
    ];
    String today = Datetime.newInstanceGmt(
        LineDailyEventSyncBatch.today(LineDailyEventSyncBatch.orgTimeZone()),
        Time.newInstance(0, 0, 0, 0)
      )
      .formatGmt('yyyy-MM-dd');
    Assert.areEqual(c.Id + ':' + today, e.LINE_Sync_Key__c, 'Today so far');
  }

  @IsTest
  static void nightlyCredentialsCheckSkipsRemovedOAs() {
    LineTestFactory.ensurePackageAccess();
    LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
    LINE_OA_Configuration__c removed = LineTestFactory.newOAConfig(
      LineTestFactory.CHANNEL_B,
      LineTestFactory.BOT_B,
      UserInfo.getUserId()
    );
    removed.Is_Active__c = false;
    removed.Credential_Status__c = 'Removed';
    insert as system removed;
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());

    Test.startTest();
    Integer queued = LineScheduler.checkCredentials();
    Test.stopTest();

    Assert.areEqual(1, queued, 'Only the OA that still has a secret');
    Assert.areEqual(
      'Valid',
      [
        SELECT Credential_Status__c
        FROM LINE_OA_Configuration__c
        WHERE Channel_Id__c = :LineTestFactory.CHANNEL_A
        WITH SYSTEM_MODE
      ]
      .Credential_Status__c
    );
  }

  @IsTest
  static void nightlyRunChecksCredentialsEvenWhileDailySyncIsOff() {
    LineTestFactory.ensurePackageAccess();
    insert as system new LINE_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Daily_Sync_Enabled__c = false
    );
    LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());

    Test.startTest();
    new LineScheduler().execute(null);
    Test.stopTest();

    Assert.areEqual(0, syncRuns());
    Assert.areEqual(
      'Valid',
      [
        SELECT Credential_Status__c
        FROM LINE_OA_Configuration__c
        WITH SYSTEM_MODE
      ]
      .Credential_Status__c
    );
  }
}
