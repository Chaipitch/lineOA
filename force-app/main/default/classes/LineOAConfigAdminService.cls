/**
 * OA administration (05 Part D). Callouts first, then DML (hard rule 6).
 * `removeOA` (DEC-33) is the only way a subscriber can get rid of a channel secret: the protected setting is unreachable
 * for them, and LINE sends no event when a channel is deleted.
 * M3: `registerOA` (callable from anonymous Apex). M8 adds rotate, reassign and deactivate, and the
 * `LineAdminController` entry point that checks the `LINE_Admin` custom permission before calling this class.
 *
 * `without sharing` (02 §2): writes the protected credential setting and OA configurations on behalf of an admin
 * whose permission is checked by the caller.
 */
public without sharing class LineOAConfigAdminService {
  private static final Integer NAME_LENGTH = 80;
  private static final Integer URL_LENGTH = 255;
  @TestVisible
  static final String CREDENTIAL_VALID = 'Valid';
  @TestVisible
  static final String CREDENTIAL_REMOVED = 'Removed';

  /** Registration outcome. Never contains the secret or a token. */
  public class RegistrationResult {
    public Id oaConfigId;
    public String name;
    public String basicId;
    public String botUserId;
    public String webhookUrl;
    public String webhookStatus;
  }

  /** A validation problem the admin can fix; the message is a Custom Label. */
  public class AdminException extends Exception {
  }

  /**
   * Registers (or re-registers) a LINE OA:
   * 1. issues a token (checks ID + secret), 2. reads bot info, 3. sets the webhook URL — all callouts;
   * 4. upserts the OA configuration by Channel ID and stores the secret — DML;
   * 5. queues a webhook test, which needs the saved configuration to route LINE's test call.
   *
   * @param channelId LINE channel ID
   * @param channelSecret channel secret (stored only in the protected setting)
   * @param repId the rep who will own the OA's conversations (active user)
   * @return what was registered
   * @throws LineApiException when LINE rejects the credentials or a call (nothing is saved)
   * @throws AdminException when the input or settings are incomplete (nothing is called or saved)
   */
  public static RegistrationResult registerOA(
    String channelId,
    String channelSecret,
    Id repId
  ) {
    String webhookUrl = LineSettings.webhookUrl();
    if (webhookUrl == null) {
      throw new AdminException(System.Label.LINE_Error_Site_Url_Missing);
    }
    if (
      repId == null ||
      [
        SELECT COUNT()
        FROM User
        WHERE Id = :repId AND IsActive = TRUE
        WITH SYSTEM_MODE
      ] == 0
    ) {
      throw new AdminException(System.Label.LINE_Error_Rep_Inactive);
    }
    String cleanChannelId = channelId == null ? null : channelId.trim();

    // 1–3: callouts
    LineApiClient client = LineApiClient.withCredentials(
      cleanChannelId,
      channelSecret == null ? null : channelSecret.trim()
    );
    client.issueToken();
    LineApiModels.BotInfo bot = client.getBotInfo();
    client.setWebhookEndpoint(webhookUrl);

    // 4: DML
    LINE_OA_Configuration__c oa = new LINE_OA_Configuration__c(
      Channel_Id__c = cleanChannelId,
      Name = String.isBlank(bot.displayName)
        ? cleanChannelId
        : bot.displayName.left(NAME_LENGTH),
      Bot_User_Id__c = bot.userId,
      Basic_Id__c = bot.basicId,
      Picture_Url__c = bot.pictureUrl != null &&
        bot.pictureUrl.length() <= URL_LENGTH
        ? bot.pictureUrl
        : null,
      Assigned_Rep__c = repId,
      Is_Active__c = true,
      Webhook_Status__c = System.Label.LINE_Webhook_Test_Pending,
      Last_Verified_At__c = Datetime.now(),
      // A token was just issued with these credentials, so LINE accepts them. Also restores a removed OA.
      Credential_Status__c = CREDENTIAL_VALID,
      Credential_Checked_At__c = Datetime.now()
    );
    Database.upsert(
      oa,
      LINE_OA_Configuration__c.Channel_Id__c,
      true,
      AccessLevel.SYSTEM_MODE
    );
    LineCredentialStore.putSecret(cleanChannelId, channelSecret.trim());

    // 5: async webhook test
    LineCalloutQueueable.enqueue(
      new List<LineCalloutQueueable.WorkItem>{
        LineCalloutQueueable.webhookTestItem(oa.Id, cleanChannelId)
      }
    );

    RegistrationResult result = new RegistrationResult();
    result.oaConfigId = oa.Id;
    result.name = oa.Name;
    result.basicId = oa.Basic_Id__c;
    result.botUserId = oa.Bot_User_Id__c;
    result.webhookUrl = webhookUrl;
    result.webhookStatus = oa.Webhook_Status__c;
    return result;
  }

  /**
   * Removes an OA (DEC-33): deletes its channel secret and keeps the OA record, inactive and marked *Removed*, so its
   * conversations and messages stay as history. Afterwards the webhook rejects that OA's calls (no secret, so no valid
   * signature) and nothing can be sent through it. Registering the OA again restores it.
   *
   * No callouts. Conversations keep their current owner; new ones would go to the fallback owner.
   *
   * @param oaConfigId the OA to remove
   * @throws AdminException when the OA doesn't exist
   */
  public static void removeOA(Id oaConfigId) {
    List<LINE_OA_Configuration__c> found = oaConfigId == null
      ? new List<LINE_OA_Configuration__c>()
      : [
          SELECT Id, Channel_Id__c
          FROM LINE_OA_Configuration__c
          WHERE Id = :oaConfigId
          WITH SYSTEM_MODE
        ];
    if (found.isEmpty()) {
      throw new AdminException(System.Label.LINE_Error_OA_Not_Found);
    }
    LINE_OA_Configuration__c oa = found[0];
    Database.update(
      new LINE_OA_Configuration__c(
        Id = oa.Id,
        Is_Active__c = false,
        Credential_Status__c = CREDENTIAL_REMOVED,
        Credential_Checked_At__c = Datetime.now()
      ),
      true,
      AccessLevel.SYSTEM_MODE
    );
    LineCredentialStore.remove(oa.Channel_Id__c);
  }

  /**
   * Rotates an OA's channel secret (R7, DEC-45): after the admin issues a new secret in the LINE Developers Console,
   * this proves it with LINE and replaces the stored one. LINE keeps one secret per channel, so webhooks and sends fail
   * from the moment LINE issues it until this runs; the admin pastes it straight away.
   *
   * Callout first (a token issued with the new secret proves it belongs to this channel), then the writes. A wrong
   * secret changes nothing. The secret is never returned, logged or stored anywhere but `LINE_OA_Credential__c`.
   *
   * @param oaConfigId the OA
   * @param channelSecret the new secret from the LINE Developers Console
   * @throws AdminException when the OA is unknown or removed, or the secret is blank
   * @throws LineApiException when LINE doesn't accept the secret
   */
  public static void rotateSecret(Id oaConfigId, String channelSecret) {
    List<LINE_OA_Configuration__c> found = oaConfigId == null
      ? new List<LINE_OA_Configuration__c>()
      : [
          SELECT Id, Channel_Id__c, Credential_Status__c
          FROM LINE_OA_Configuration__c
          WHERE Id = :oaConfigId
          WITH SYSTEM_MODE
        ];
    if (found.isEmpty()) {
      throw new AdminException(System.Label.LINE_Error_OA_Not_Found);
    }
    LINE_OA_Configuration__c oa = found[0];
    if (oa.Credential_Status__c == CREDENTIAL_REMOVED) {
      // A removed OA is brought back by registering it, which also re-points the webhook.
      throw new AdminException(System.Label.LINE_Error_Rotate_Removed);
    }
    if (String.isBlank(channelSecret)) {
      throw new AdminException(System.Label.LINE_Error_Secret_Required);
    }
    String secret = channelSecret.trim();

    // 1. Callout: the old secret's cached token must not be reused for the check.
    LineApiClient.clearTokenCache();
    LineApiClient.withCredentials(oa.Channel_Id__c, secret).issueToken();

    // 2. DML
    LineCredentialStore.putSecret(oa.Channel_Id__c, secret);
    Database.update(
      new LINE_OA_Configuration__c(
        Id = oa.Id,
        Credential_Status__c = CREDENTIAL_VALID,
        Credential_Checked_At__c = Datetime.now()
      ),
      true,
      AccessLevel.SYSTEM_MODE
    );
  }
}
