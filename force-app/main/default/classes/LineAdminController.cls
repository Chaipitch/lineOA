/**
 * LWC API for the LINE Admin app page (02 §2).
 *
 * Every method checks the `LINE_Admin` custom permission first, on top of object permissions: admin work must not be
 * reachable by a rep who happens to know the method names.
 *
 * This is the part of M8 that had to come early: in a subscriber org only `global` members are callable, and by design
 * the only global class is the webhook (hard rule 2). Without this page there is no way to register an OA in an
 * installed package, so betas could not be tested end to end (08, DEC-25).
 */
public with sharing class LineAdminController {
  // The last error turned into a generic message, so tests can show what really happened.
  @TestVisible
  static Exception lastUnexpectedError;

  /** Org-wide settings, as shown on the admin page. */
  public class SettingsView {
    @AuraEnabled
    public String siteBaseUrl;
    /** Read-only: what to paste into the LINE Developers Console, namespace included. */
    @AuraEnabled
    public String webhookUrl;
    @AuraEnabled
    public Id fallbackOwnerId;
    @AuraEnabled
    public Integer pollIntervalSeconds;
    @AuraEnabled
    public Integer inviteCodeExpiryDays;
    @AuraEnabled
    public Integer publicLinkExpiryDays;
    @AuraEnabled
    public Integer messageRetentionMonths;
    @AuraEnabled
    public Boolean dailySyncEnabled;
    @AuraEnabled
    public Boolean updateContactOwnerOnReassign;
  }

  /** One registered OA. Never carries the channel secret. */
  public class OaView {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String channelId;
    @AuraEnabled
    public String basicId;
    @AuraEnabled
    public String botUserId;
    @AuraEnabled
    public Id assignedRepId;
    @AuraEnabled
    public String assignedRepName;
    @AuraEnabled
    public Boolean isActive;
    @AuraEnabled
    public String webhookStatus;
    @AuraEnabled
    public Datetime lastVerifiedAt;

    private OaView(LINE_OA_Configuration__c oa) {
      this.id = oa.Id;
      this.name = oa.Name;
      this.channelId = oa.Channel_Id__c;
      this.basicId = oa.Basic_Id__c;
      this.botUserId = oa.Bot_User_Id__c;
      this.assignedRepId = oa.Assigned_Rep__c;
      this.assignedRepName = oa.Assigned_Rep__r?.Name;
      this.isActive = oa.Is_Active__c;
      this.webhookStatus = oa.Webhook_Status__c;
      this.lastVerifiedAt = oa.Last_Verified_At__c;
    }
  }

  /**
   * @return the current settings, plus the webhook URL built from the Site base URL and the namespace
   */
  @AuraEnabled
  public static SettingsView getSettings() {
    try {
      assertAdmin();
      return currentSettings();
    } catch (Exception e) {
      throw handled(e, 'getSettings');
    }
  }

  /**
   * Saves the org-level settings. Blank numbers fall back to the defaults in `LineSettings`.
   *
   * @param siteBaseUrl public Site base URL, including any path prefix
   * @param fallbackOwnerId user or queue owning conversations of inactive OAs
   * @param pollIntervalSeconds chat panel poll interval
   * @param inviteCodeExpiryDays QR invite lifetime
   * @param publicLinkExpiryDays outbound file link lifetime
   * @param messageRetentionMonths months to keep messages, 0 = forever
   * @param dailySyncEnabled whether the nightly Event sync runs
   * @param updateContactOwnerOnReassign whether reassigning an OA also moves Contact ownership
   * @return the saved settings
   */
  @AuraEnabled
  public static SettingsView saveSettings(
    String siteBaseUrl,
    Id fallbackOwnerId,
    Integer pollIntervalSeconds,
    Integer inviteCodeExpiryDays,
    Integer publicLinkExpiryDays,
    Integer messageRetentionMonths,
    Boolean dailySyncEnabled,
    Boolean updateContactOwnerOnReassign
  ) {
    try {
      assertAdmin();
      LINE_Settings__c settings = LINE_Settings__c.getOrgDefaults();
      if (settings == null || settings.Id == null) {
        settings = new LINE_Settings__c(
          SetupOwnerId = UserInfo.getOrganizationId()
        );
      }
      settings.Site_Base_Url__c = String.isBlank(siteBaseUrl)
        ? null
        : siteBaseUrl.trim().removeEnd('/');
      settings.Fallback_Owner_Id__c = fallbackOwnerId;
      settings.Poll_Interval_Seconds__c = pollIntervalSeconds;
      settings.Invite_Code_Expiry_Days__c = inviteCodeExpiryDays;
      settings.Public_Link_Expiry_Days__c = publicLinkExpiryDays;
      settings.Message_Retention_Months__c = messageRetentionMonths;
      settings.Daily_Sync_Enabled__c = dailySyncEnabled == true;
      settings.Update_Contact_Owner_On_Reassign__c =
        updateContactOwnerOnReassign == true;
      // Custom settings carry no sharing or field-level security of their own; the admin check above is the gate.
      upsert as system settings;
      LineSettings.reset();
      return currentSettings();
    } catch (Exception e) {
      throw handled(e, 'saveSettings');
    }
  }

  /**
   * @return every registered OA, newest first
   */
  @AuraEnabled
  public static List<OaView> getOAs() {
    try {
      assertAdmin();
      List<OaView> result = new List<OaView>();
      for (LINE_OA_Configuration__c oa : [
        SELECT
          Id,
          Name,
          Channel_Id__c,
          Basic_Id__c,
          Bot_User_Id__c,
          Assigned_Rep__c,
          Assigned_Rep__r.Name,
          Is_Active__c,
          Webhook_Status__c,
          Last_Verified_At__c
        FROM LINE_OA_Configuration__c
        WITH USER_MODE
        ORDER BY Name
        LIMIT 200
      ]) {
        result.add(new OaView(oa));
      }
      return result;
    } catch (Exception e) {
      throw handled(e, 'getOAs');
    }
  }

  /**
   * Registers a LINE OA: checks the credentials with LINE, reads the OA details, points its webhook at this org,
   * then stores the configuration and the secret (05 Part D).
   *
   * @param channelId LINE channel ID
   * @param channelSecret channel secret; stored only in the protected custom setting and never returned
   * @param repId the rep who owns this OA's conversations
   * @return the registered OA
   */
  @AuraEnabled
  public static OaView registerOA(
    String channelId,
    String channelSecret,
    Id repId
  ) {
    try {
      assertAdmin();
      LineOAConfigAdminService.RegistrationResult result = LineOAConfigAdminService.registerOA(
        channelId,
        channelSecret,
        repId
      );
      for (OaView oa : getOAs()) {
        if (oa.id == result.oaConfigId) {
          return oa;
        }
      }
      List<OaView> visible = getOAs();
      throw new LineOAConfigAdminService.AdminException(
        'DIAG expected ' +
          result.oaConfigId +
          ' among ' +
          visible.size() +
          ' rows'
      );
    } catch (Exception e) {
      throw handled(e, 'registerOA');
    }
  }

  // ---------------------------------------------------------------------------------------------------------------

  private static SettingsView currentSettings() {
    LineSettings.reset();
    SettingsView view = new SettingsView();
    view.siteBaseUrl = LineSettings.siteBaseUrl();
    view.webhookUrl = LineSettings.webhookUrl();
    view.fallbackOwnerId = LineSettings.fallbackOwnerId();
    view.pollIntervalSeconds = LineSettings.pollIntervalSeconds();
    view.inviteCodeExpiryDays = LineSettings.inviteCodeExpiryDays();
    view.publicLinkExpiryDays = LineSettings.publicLinkExpiryDays();
    view.messageRetentionMonths = LineSettings.messageRetentionMonths();
    view.dailySyncEnabled = LineSettings.dailySyncEnabled();
    view.updateContactOwnerOnReassign = LineSettings.updateContactOwnerOnReassign();
    return view;
  }

  // The custom permission is the gate for admin work, on top of the object permissions in LINE_Admin.
  @TestVisible
  private static void assertAdmin() {
    if (!FeatureManagement.checkPermission('LINE_Admin')) {
      throw asAuraException(System.Label.LINE_Error_Admin_Only);
    }
  }

  private static AuraHandledException handled(Exception e, String method) {
    if (e instanceof AuraHandledException) {
      return (AuraHandledException) e;
    }
    if (e instanceof LineApiException) {
      // LINE's own wording tells the admin whether the credentials or the URL are wrong.
      return asAuraException(((LineApiException) e).userMessage());
    }
    if (
      e instanceof LineOAConfigAdminService.AdminException ||
      e instanceof IllegalArgumentException
    ) {
      return asAuraException(e.getMessage());
    }
    if (e instanceof QueryException || e instanceof System.NoAccessException) {
      return asAuraException(System.Label.LINE_Error_No_Access);
    }
    lastUnexpectedError = e;
    LineLogger.error('LineAdminController.' + method, e);
    LineLogger.flush();
    return asAuraException(System.Label.LINE_Error_Generic);
  }

  private static AuraHandledException asAuraException(String message) {
    AuraHandledException e = new AuraHandledException(message);
    // Without this the LWC only sees "Script-thrown exception".
    e.setMessage(message);
    return e;
  }
}
