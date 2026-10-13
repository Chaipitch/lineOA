@IsTest
private class LineCalloutQueueableTest {
  @TestSetup
  static void setup() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c oa = LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
    insert as system new List<LINE_Conversation__c>{
      new LINE_Conversation__c(
        Name = 'Ucustomer1',
        LINE_OA_Configuration__c = oa.Id,
        LINE_User_Id__c = 'Ucustomer1',
        Unique_Key__c = LineTestFactory.CHANNEL_A + ':Ucustomer1'
      ),
      new LINE_Conversation__c(
        Name = 'Ucustomer2',
        LINE_OA_Configuration__c = oa.Id,
        LINE_User_Id__c = 'Ucustomer2',
        Unique_Key__c = LineTestFactory.CHANNEL_A + ':Ucustomer2'
      )
    };
  }

  private static LINE_OA_Configuration__c oa() {
    return [
      SELECT Id, Channel_Id__c, Webhook_Status__c, Last_Verified_At__c
      FROM LINE_OA_Configuration__c
      WITH SYSTEM_MODE
    ];
  }

  private static LineCalloutQueueable.WorkItem profileItem(String userId) {
    LINE_Conversation__c c = [
      SELECT Id, LINE_OA_Configuration__c
      FROM LINE_Conversation__c
      WHERE LINE_User_Id__c = :userId
      WITH SYSTEM_MODE
    ];
    return LineCalloutQueueable.profileItem(
      c.Id,
      c.LINE_OA_Configuration__c,
      LineTestFactory.CHANNEL_A,
      userId
    );
  }

  @IsTest
  static void profileUpdatesNameAndPicture() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    LineCalloutQueueable.enqueue(
      new List<LineCalloutQueueable.WorkItem>{ profileItem('Ucustomer1') }
    );
    Test.stopTest();

    LINE_Conversation__c c = [
      SELECT Name, Picture_Url__c
      FROM LINE_Conversation__c
      WHERE LINE_User_Id__c = 'Ucustomer1'
      WITH SYSTEM_MODE
    ];
    Assert.areEqual('Somchai', c.Name);
    Assert.areEqual('https://example.com/u.png', c.Picture_Url__c);
    Assert.areEqual(1, mock.requestsTo('/v2/bot/profile/Ucustomer1').size());
  }

  @IsTest
  static void profileFailureIsLoggedAndNameKept() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    mock.stub('GET', '/v2/bot/profile/', 404, '{"message":"Not found"}');
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    LineCalloutQueueable.enqueue(
      new List<LineCalloutQueueable.WorkItem>{ profileItem('Ucustomer1') }
    );
    Test.stopTest();

    Assert.areEqual(
      'Ucustomer1',
      [
        SELECT Name
        FROM LINE_Conversation__c
        WHERE LINE_User_Id__c = 'Ucustomer1'
        WITH SYSTEM_MODE
      ]
      .Name
    );
    LINE_Error_Log__c log = [
      SELECT Source__c, Http_Status__c, Related_Record_Id__c
      FROM LINE_Error_Log__c
      WITH SYSTEM_MODE
    ];
    Assert.areEqual('LineCalloutQueueable.PROFILE', log.Source__c);
    Assert.areEqual(404, log.Http_Status__c);
  }

  @IsTest
  static void webhookTestRecordsResult() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    LINE_OA_Configuration__c before = oa();

    Test.startTest();
    LineCalloutQueueable.enqueue(
      new List<LineCalloutQueueable.WorkItem>{
        LineCalloutQueueable.webhookTestItem(before.Id, before.Channel_Id__c)
      }
    );
    Test.stopTest();

    LINE_OA_Configuration__c after = oa();
    Assert.areEqual('OK (200 OK)', after.Webhook_Status__c);
    Assert.isNotNull(after.Last_Verified_At__c);
  }

  @IsTest
  static void webhookTestFailureIsRecorded() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    mock.stub(
      'POST',
      '/v2/bot/channel/webhook/test',
      200,
      '{"success":false,"statusCode":403,"reason":"FORBIDDEN","detail":"403"}'
    );
    Test.setMock(HttpCalloutMock.class, mock);
    LINE_OA_Configuration__c before = oa();

    Test.startTest();
    LineCalloutQueueable.enqueue(
      new List<LineCalloutQueueable.WorkItem>{
        LineCalloutQueueable.webhookTestItem(before.Id, before.Channel_Id__c)
      }
    );
    Test.stopTest();

    Assert.areEqual('Failed (403 FORBIDDEN)', oa().Webhook_Status__c);
  }

  @IsTest
  static void webhookTestApiErrorIsRecorded() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    mock.stub(
      'POST',
      '/v2/bot/channel/webhook/test',
      500,
      '{"message":"LINE error"}'
    );
    Test.setMock(HttpCalloutMock.class, mock);
    LINE_OA_Configuration__c before = oa();

    Test.startTest();
    LineCalloutQueueable.enqueue(
      new List<LineCalloutQueueable.WorkItem>{
        LineCalloutQueueable.webhookTestItem(before.Id, before.Channel_Id__c)
      }
    );
    Test.stopTest();

    Assert.isTrue(
      oa().Webhook_Status__c.startsWith('Failed: '),
      oa().Webhook_Status__c
    );
  }

  @IsTest
  static void remainderIsChained() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    LineCalloutQueueable.itemsPerExecution = 1;

    Test.startTest();
    new LineCalloutQueueable(
        new List<LineCalloutQueueable.WorkItem>{
          profileItem('Ucustomer1'),
          profileItem('Ucustomer2')
        }
      )
      .execute(null);
    Test.stopTest();

    Assert.areEqual(1, LineCalloutQueueable.lastChainedItems.size());
    Assert.areEqual(
      'Ucustomer2',
      LineCalloutQueueable.lastChainedItems[0].lineUserId
    );
    Assert.areEqual(
      'Somchai',
      [
        SELECT Name
        FROM LINE_Conversation__c
        WHERE LINE_User_Id__c = 'Ucustomer1'
        WITH SYSTEM_MODE
      ]
      .Name
    );
  }

  @IsTest
  static void unknownItemTypeIsLogged() {
    LineTestFactory.ensurePackageAccess();
    LineCalloutQueueable.WorkItem item = new LineCalloutQueueable.WorkItem();
    item.type = 'NOPE';

    new LineCalloutQueueable(new List<LineCalloutQueueable.WorkItem>{ item })
      .execute(null);

    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM LINE_Error_Log__c
        WHERE Source__c = 'LineCalloutQueueable.run'
        WITH SYSTEM_MODE
      ]
    );
  }

  @IsTest
  static void enqueueIgnoresEmptyWork() {
    LineTestFactory.ensurePackageAccess();
    Assert.isNull(LineCalloutQueueable.enqueue(null));
    Assert.isNull(
      LineCalloutQueueable.enqueue(new List<LineCalloutQueueable.WorkItem>())
    );
    new LineCalloutQueueable(null).execute(null);
  }

  // ---------- credentials check (DEC-33) ----------

  private static LINE_OA_Configuration__c credentials() {
    return [
      SELECT Credential_Status__c, Credential_Checked_At__c
      FROM LINE_OA_Configuration__c
      WITH SYSTEM_MODE
    ];
  }

  private static void runCredentialCheck() {
    LINE_OA_Configuration__c o = oa();
    Test.startTest();
    LineCalloutQueueable.enqueue(
      new List<LineCalloutQueueable.WorkItem>{
        LineCalloutQueueable.credentialCheckItem(o.Id, o.Channel_Id__c)
      }
    );
    Test.stopTest();
  }

  @IsTest
  static void credentialCheckMarksAcceptedCredentialsValid() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());

    runCredentialCheck();

    Assert.areEqual('Valid', credentials().Credential_Status__c);
    Assert.isNotNull(credentials().Credential_Checked_At__c);
  }

  @IsTest
  static void credentialCheckFlagsCredentialsLineRejects() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    mock.stub(
      'POST',
      '/oauth2/v3/token',
      400,
      '{"error":"invalid_client","error_description":"invalid client"}'
    );
    Test.setMock(HttpCalloutMock.class, mock);

    runCredentialCheck();

    Assert.areEqual('Rejected', credentials().Credential_Status__c);
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM LINE_Error_Log__c
        WHERE Source__c = 'LineCalloutQueueable.CREDENTIAL_CHECK'
        WITH SYSTEM_MODE
      ],
      'Also logged for the admin'
    );
  }

  @IsTest
  static void credentialCheckLeavesTheStatusAloneWhenLineCannotBeReached() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c o = oa();
    update as system new LINE_OA_Configuration__c(
      Id = o.Id,
      Credential_Status__c = 'Valid'
    );
    LineHttpMock mock = new LineHttpMock();
    mock.stubCalloutException('POST', '/oauth2/v3/token');
    Test.setMock(HttpCalloutMock.class, mock);

    runCredentialCheck();

    Assert.areEqual(
      'Valid',
      credentials().Credential_Status__c,
      'An outage is not a rejection'
    );
    Assert.isNull(credentials().Credential_Checked_At__c);
  }

  @IsTest
  static void credentialCheckFlagsAnOAWithNoStoredSecret() {
    LineTestFactory.ensurePackageAccess();
    LineCredentialStore.remove(LineTestFactory.CHANNEL_A);
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());

    runCredentialCheck();

    Assert.areEqual('Rejected', credentials().Credential_Status__c);
  }

  // ---------- invite replies (D10) ----------

  @IsTest
  static void expiredReplyTokenIsLoggedAndNeverPushed() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    mock.stub(
      'POST',
      '/v2/bot/message/reply',
      400,
      '{"message":"Invalid reply token"}'
    );
    Test.setMock(HttpCalloutMock.class, mock);
    LINE_Conversation__c c = [
      SELECT Id, LINE_OA_Configuration__c
      FROM LINE_Conversation__c
      WHERE LINE_User_Id__c = 'Ucustomer1'
      WITH SYSTEM_MODE
    ];

    Test.startTest();
    LineCalloutQueueable.enqueue(
      new List<LineCalloutQueueable.WorkItem>{
        LineCalloutQueueable.inviteReplyItem(
          c.Id,
          c.LINE_OA_Configuration__c,
          LineTestFactory.CHANNEL_A,
          'reply-token-1',
          LineCalloutQueueable.INVITE_LINKED
        )
      }
    );
    Test.stopTest();

    Assert.areEqual(0, mock.requestsTo('/v2/bot/message/push').size());
    Assert.areEqual(
      'LineCalloutQueueable.INVITE_REPLY',
      [SELECT Source__c FROM LINE_Error_Log__c WITH SYSTEM_MODE].Source__c
    );
  }

  // ---------- downloads (M7) ----------

  private static LINE_Message__c inboundMedia(
    String type,
    String lineMessageId
  ) {
    LINE_Conversation__c c = [
      SELECT Id
      FROM LINE_Conversation__c
      WHERE LINE_User_Id__c = 'Ucustomer1'
      WITH SYSTEM_MODE
    ];
    LINE_Message__c m = new LINE_Message__c(
      LINE_Conversation__c = c.Id,
      Direction__c = 'Inbound',
      Message_Type__c = type,
      Status__c = 'Downloading',
      Sent_At__c = Datetime.now(),
      Line_Message_Id__c = lineMessageId,
      Webhook_Event_Id__c = 'evt-' + lineMessageId
    );
    insert as system m;
    return m;
  }

  private static LineCalloutQueueable.WorkItem downloadOf(LINE_Message__c m) {
    return LineCalloutQueueable.downloadItem(
      m.Id,
      m.LINE_Conversation__c,
      oa().Id,
      LineTestFactory.CHANNEL_A,
      m.Line_Message_Id__c,
      m.Message_Type__c,
      null
    );
  }

  private static String statusOf(Id messageId) {
    return [
      SELECT Status__c
      FROM LINE_Message__c
      WHERE Id = :messageId
      WITH SYSTEM_MODE
    ]
    .Status__c;
  }

  @IsTest
  static void downloadFailureIsRecordedOnTheMessage() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    mock.stub('GET', '/content', 404, '{"message":"Not found"}');
    Test.setMock(HttpCalloutMock.class, mock);
    LINE_Message__c m = inboundMedia('image', '9001');

    Test.startTest();
    new LineCalloutQueueable(
        new List<LineCalloutQueueable.WorkItem>{ downloadOf(m) }
      )
      .execute(null);
    Test.stopTest();

    Assert.areEqual('Download Failed', statusOf(m.Id));
  }

  @IsTest
  static void contentOverTheLimitIsTooLarge() {
    LineTestFactory.ensurePackageAccess();
    insert as system new LINE_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Max_Download_Bytes__c = 3
    );
    LineSettings.reset();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    LINE_Message__c m = inboundMedia('image', '9002');

    Test.startTest();
    new LineCalloutQueueable(
        new List<LineCalloutQueueable.WorkItem>{ downloadOf(m) }
      )
      .execute(null);
    Test.stopTest();

    Assert.areEqual('Too Large', statusOf(m.Id));
    Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WITH SYSTEM_MODE]);
  }

  @IsTest
  static void videoStillTranscodingIsRetriedLater() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    mock.stub('GET', '/content/transcoding', 200, '{"status":"processing"}');
    Test.setMock(HttpCalloutMock.class, mock);
    LINE_Message__c m = inboundMedia('video', '9003');

    Test.startTest();
    new LineCalloutQueueable(
        new List<LineCalloutQueueable.WorkItem>{ downloadOf(m) }
      )
      .execute(null);
    Test.stopTest();

    Assert.areEqual(1, LineCalloutQueueable.lastDelayedItems.size());
    Assert.areEqual(1, LineCalloutQueueable.lastDelayedItems[0].attempts);
    Assert.areEqual('Downloading', statusOf(m.Id), 'Not failed yet');
  }

  @IsTest
  static void downloadsBeyondTheMemoryBudgetMoveToTheNextRun() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    LineCalloutQueueable.downloadBytesPerExecution = 1;
    LINE_Message__c first = inboundMedia('image', '9004');
    LINE_Message__c second = inboundMedia('image', '9005');

    Test.startTest();
    new LineCalloutQueueable(
        new List<LineCalloutQueueable.WorkItem>{
          downloadOf(first),
          downloadOf(second)
        }
      )
      .execute(null);
    Test.stopTest();

    Assert.areEqual('Received', statusOf(first.Id));
    Assert.areEqual('Downloading', statusOf(second.Id));
    Assert.areEqual(1, LineCalloutQueueable.lastChainedItems.size());
    Assert.areEqual(
      second.Id,
      LineCalloutQueueable.lastChainedItems[0].recordId
    );
  }

  @IsTest
  static void extensionsFollowTheContentType() {
    Assert.areEqual('.jpg', LineCalloutQueueable.extensionFor('image/jpeg'));
    Assert.areEqual(
      '.png',
      LineCalloutQueueable.extensionFor('image/png; charset=binary')
    );
    Assert.areEqual('.mp4', LineCalloutQueueable.extensionFor('video/mp4'));
    Assert.areEqual('.m4a', LineCalloutQueueable.extensionFor('audio/x-m4a'));
    Assert.areEqual('.bin', LineCalloutQueueable.extensionFor(null));
  }
}
