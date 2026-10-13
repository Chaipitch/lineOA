/**
 * Sending files (M7, DEC-43). The public links are created in @TestSetup: a test can't make a callout after DML in
 * the same transaction, which is exactly why the panel calls prepareFile and sendFile separately.
 */
@IsTest
private class LineFileSendTest {
  @TestSetup
  static void setup() {
    LineTestFactory.ensurePackageAccess();
    User rep = LineTestFactory.createUser(new List<String>{ 'LINE_Chat_User' });
    LINE_OA_Configuration__c oa = LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      rep.Id
    );
    LINE_Conversation__c c = new LINE_Conversation__c(
      Name = 'Somchai',
      LINE_OA_Configuration__c = oa.Id,
      LINE_User_Id__c = 'Ucustomer1',
      Unique_Key__c = LineTestFactory.CHANNEL_A + ':Ucustomer1',
      Status__c = 'Following',
      OwnerId = rep.Id
    );
    insert as system c;
    List<ContentVersion> files = new List<ContentVersion>{
      file('photo', 'photo.jpg', c.Id),
      file('quote', 'quote.pdf', c.Id)
    };
    insert as system files;
    List<ContentDistribution> links = new List<ContentDistribution>();
    for (ContentVersion v : files) {
      links.add(
        new ContentDistribution(
          Name = v.Title,
          ContentVersionId = v.Id,
          PreferencesAllowViewInBrowser = true,
          PreferencesExpires = true,
          ExpiryDate = Datetime.now().addDays(7)
        )
      );
    }
    insert as system links;
  }

  private static ContentVersion file(
    String title,
    String path,
    Id conversationId
  ) {
    return new ContentVersion(
      Title = title,
      PathOnClient = path,
      VersionData = Blob.valueOf('fake-binary'),
      FirstPublishLocationId = conversationId
    );
  }

  private static User rep() {
    return [
      SELECT Id
      FROM User
      WHERE Id IN (SELECT Assigned_Rep__c FROM LINE_OA_Configuration__c)
      WITH SYSTEM_MODE
      LIMIT 1
    ];
  }

  private static Id conversationId() {
    return [SELECT Id FROM LINE_Conversation__c WITH SYSTEM_MODE LIMIT 1].Id;
  }

  private static Id documentOf(String title) {
    return [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Title = :title
      WITH SYSTEM_MODE
      LIMIT 1
    ]
    .ContentDocumentId;
  }

  @IsTest
  static void smallJpegGoesAsAPicture() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);
    Id documentId = documentOf('photo');

    LineChatController.MessageView sent;
    Test.startTest();
    System.runAs(rep()) {
      sent = LineChatController.sendFile(conversationId(), documentId);
    }
    Test.stopTest();

    Assert.areEqual('image', sent.messageType);
    Assert.areEqual('Sent', sent.status);
    Assert.areEqual(String.valueOf(documentId), sent.contentDocumentId);
    String body = mock.requestsTo('/v2/bot/message/push')[0].getBody();
    Assert.isTrue(body.contains('"type":"image"'), body);
    Assert.isTrue(body.contains('originalContentUrl'), 'Sent as a LINE image');
  }

  @IsTest
  static void documentGoesAsAnExpiringLink() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);

    Id documentId = documentOf('quote');
    LineChatController.MessageView sent;
    Test.startTest();
    System.runAs(rep()) {
      sent = LineChatController.sendFile(conversationId(), documentId);
    }
    Test.stopTest();

    Assert.areEqual('file', sent.messageType);
    Assert.isNotNull(sent.publicUrl);
    String body = mock.requestsTo('/v2/bot/message/push')[0].getBody();
    Assert.isTrue(body.contains('"type":"text"'), body);
    Assert.areEqual(
      'quote.pdf',
      [
        SELECT Last_Message_Preview__c
        FROM LINE_Conversation__c
        WITH SYSTEM_MODE
      ]
      .Last_Message_Preview__c,
      'The inbox preview shows the file name'
    );
  }

  @IsTest
  static void prepareFileCreatesAnExpiringLink() {
    LineTestFactory.ensurePackageAccess();
    Id documentId = documentOf('quote');
    Integer before = [SELECT COUNT() FROM ContentDistribution WITH SYSTEM_MODE];

    Test.startTest();
    System.runAs(rep()) {
      LineChatController.prepareFile(conversationId(), documentId);
    }
    Test.stopTest();

    ContentDistribution link = [
      SELECT PreferencesExpires, ExpiryDate
      FROM ContentDistribution
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    Assert.areEqual(
      before + 1,
      [SELECT COUNT() FROM ContentDistribution WITH SYSTEM_MODE]
    );
    Assert.isTrue(link.PreferencesExpires);
    Assert.isTrue(
      link.ExpiryDate > Datetime.now().addDays(6),
      'Seven days by default'
    );
  }

  @IsTest
  static void aFileNotUploadedToTheConversationIsRefused() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);
    User r = rep();
    // The rep's own file, never attached to this conversation.
    ContentVersion other = new ContentVersion(
      Title = 'private',
      PathOnClient = 'private.pdf',
      VersionData = Blob.valueOf('x')
    );
    System.runAs(r) {
      insert other;
    }
    Id otherDocument = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :other.Id
      WITH SYSTEM_MODE
    ]
    .ContentDocumentId;

    String message;
    System.runAs(r) {
      try {
        LineChatController.prepareFile(conversationId(), otherDocument);
      } catch (AuraHandledException e) {
        message = e.getMessage();
      }
    }
    Assert.areEqual(System.Label.LINE_Error_No_Access, message);
    Assert.areEqual(0, mock.requests.size());
  }
}
