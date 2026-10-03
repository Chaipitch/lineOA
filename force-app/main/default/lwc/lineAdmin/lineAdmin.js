import { LightningElement, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import LightningConfirm from "lightning/confirm";

import getSettings from "@salesforce/apex/LineAdminController.getSettings";
import saveSettings from "@salesforce/apex/LineAdminController.saveSettings";
import getOAs from "@salesforce/apex/LineAdminController.getOAs";
import registerOA from "@salesforce/apex/LineAdminController.registerOA";
import getJobs from "@salesforce/apex/LineAdminController.getJobs";
import scheduleJobs from "@salesforce/apex/LineAdminController.scheduleJobs";
import unscheduleJobs from "@salesforce/apex/LineAdminController.unscheduleJobs";
import runDailySyncNow from "@salesforce/apex/LineAdminController.runDailySyncNow";
import removeOA from "@salesforce/apex/LineAdminController.removeOA";

import TITLE from "@salesforce/label/c.LINE_Admin_Title";
import SETTINGS from "@salesforce/label/c.LINE_Admin_Settings";
import SITE_BASE_URL from "@salesforce/label/c.LINE_Admin_Site_Base_Url";
import SITE_BASE_URL_HELP from "@salesforce/label/c.LINE_Admin_Site_Base_Url_Help";
import WEBHOOK_URL from "@salesforce/label/c.LINE_Admin_Webhook_Url";
import FALLBACK_OWNER from "@salesforce/label/c.LINE_Admin_Fallback_Owner";
import SAVE from "@salesforce/label/c.LINE_Admin_Save";
import SAVED from "@salesforce/label/c.LINE_Admin_Saved";
import OAS from "@salesforce/label/c.LINE_Admin_OAs";
import NO_OAS from "@salesforce/label/c.LINE_Admin_No_OAs";
import REGISTER from "@salesforce/label/c.LINE_Admin_Register";
import CHANNEL_ID from "@salesforce/label/c.LINE_Admin_Channel_Id";
import CHANNEL_SECRET from "@salesforce/label/c.LINE_Admin_Channel_Secret";
import CHANNEL_SECRET_HELP from "@salesforce/label/c.LINE_Admin_Channel_Secret_Help";
import ASSIGNED_REP from "@salesforce/label/c.LINE_Admin_Assigned_Rep";
import REGISTERED from "@salesforce/label/c.LINE_Admin_Registered";
import REGISTER_HELP from "@salesforce/label/c.LINE_Admin_Register_Help";
import GENERIC_ERROR from "@salesforce/label/c.LINE_Error_Generic";
import JOBS from "@salesforce/label/c.LINE_Admin_Jobs";
import JOBS_HELP from "@salesforce/label/c.LINE_Admin_Jobs_Help";
import JOBS_SCHEDULED from "@salesforce/label/c.LINE_Admin_Jobs_Scheduled";
import JOBS_NOT_SCHEDULED from "@salesforce/label/c.LINE_Admin_Jobs_Not_Scheduled";
import JOBS_LAST_RUN from "@salesforce/label/c.LINE_Admin_Jobs_Last_Run";
import JOBS_SCHEDULE from "@salesforce/label/c.LINE_Admin_Jobs_Schedule";
import JOBS_UNSCHEDULE from "@salesforce/label/c.LINE_Admin_Jobs_Unschedule";
import JOBS_RUN_NOW from "@salesforce/label/c.LINE_Admin_Jobs_Run_Now";
import JOBS_STARTED from "@salesforce/label/c.LINE_Admin_Jobs_Started";
import JOBS_SYNC_OFF from "@salesforce/label/c.LINE_Admin_Jobs_Sync_Off";
import JOBS_DAY_ZONE from "@salesforce/label/c.LINE_Admin_Jobs_Day_Zone";
import JOBS_ZONE_MISMATCH from "@salesforce/label/c.LINE_Admin_Jobs_Zone_Mismatch";
import CREDENTIALS from "@salesforce/label/c.LINE_Admin_Credentials";
import CREDENTIAL_VALID from "@salesforce/label/c.LINE_Admin_Credential_Valid";
import CREDENTIAL_REJECTED from "@salesforce/label/c.LINE_Admin_Credential_Rejected";
import CREDENTIAL_REMOVED from "@salesforce/label/c.LINE_Admin_Credential_Removed";
import CREDENTIAL_UNCHECKED from "@salesforce/label/c.LINE_Admin_Credential_Unchecked";
import REMOVE from "@salesforce/label/c.LINE_Admin_Remove";
import REMOVE_CONFIRM from "@salesforce/label/c.LINE_Admin_Remove_Confirm";
import REMOVED from "@salesforce/label/c.LINE_Admin_Removed";

/**
 * LINE Admin app page: org settings, nightly jobs and OA registration.
 * The channel secret is only ever sent to Apex; it is never read back, stored in component state, or logged.
 */
export default class LineAdmin extends LightningElement {
  @track settings = {};
  @track oas = [];
  @track jobs = {};
  jobsLoaded = false;
  isJobBusy = false;
  isLoading = true;
  isSaving = false;
  isRegistering = false;
  errorMessage;

  channelId = "";
  channelSecret = "";
  repId;

  labels = {
    title: TITLE,
    settings: SETTINGS,
    siteBaseUrl: SITE_BASE_URL,
    siteBaseUrlHelp: SITE_BASE_URL_HELP,
    webhookUrl: WEBHOOK_URL,
    fallbackOwner: FALLBACK_OWNER,
    save: SAVE,
    oas: OAS,
    noOas: NO_OAS,
    register: REGISTER,
    channelId: CHANNEL_ID,
    channelSecret: CHANNEL_SECRET,
    channelSecretHelp: CHANNEL_SECRET_HELP,
    assignedRep: ASSIGNED_REP,
    registerHelp: REGISTER_HELP,
    jobs: JOBS,
    jobsHelp: JOBS_HELP,
    jobsScheduled: JOBS_SCHEDULED,
    jobsNotScheduled: JOBS_NOT_SCHEDULED,
    jobsLastRun: JOBS_LAST_RUN,
    jobsSchedule: JOBS_SCHEDULE,
    jobsUnschedule: JOBS_UNSCHEDULE,
    jobsRunNow: JOBS_RUN_NOW,
    jobsSyncOff: JOBS_SYNC_OFF,
    jobsDayZone: JOBS_DAY_ZONE,
    jobsZoneMismatch: JOBS_ZONE_MISMATCH,
    credentials: CREDENTIALS,
    remove: REMOVE
  };

  async connectedCallback() {
    await this.refresh();
  }

  async refresh() {
    this.isLoading = true;
    try {
      this.settings = await getSettings();
      this.oas = await getOAs();
      this.jobs = await getJobs();
      this.jobsLoaded = true;
      this.errorMessage = undefined;
    } catch (error) {
      this.errorMessage = this.messageFrom(error);
    } finally {
      this.isLoading = false;
    }
  }

  // ---------- settings ----------

  handleSettingChange(event) {
    const field = event.target.dataset.field;
    const value =
      event.target.type === "checkbox"
        ? event.target.checked
        : event.target.value;
    this.settings = { ...this.settings, [field]: value };
  }

  handleFallbackOwnerChange(event) {
    this.settings = {
      ...this.settings,
      fallbackOwnerId: event.detail.recordId
    };
  }

  async handleSave() {
    this.isSaving = true;
    try {
      this.settings = await saveSettings({
        siteBaseUrl: this.settings.siteBaseUrl,
        fallbackOwnerId: this.settings.fallbackOwnerId,
        pollIntervalSeconds: this.toNumber(this.settings.pollIntervalSeconds),
        inviteCodeExpiryDays: this.toNumber(this.settings.inviteCodeExpiryDays),
        publicLinkExpiryDays: this.toNumber(this.settings.publicLinkExpiryDays),
        messageRetentionMonths: this.toNumber(
          this.settings.messageRetentionMonths
        ),
        autoCreateContact: this.settings.autoCreateContact === true,
        dailySyncEnabled: this.settings.dailySyncEnabled === true,
        updateContactOwnerOnReassign:
          this.settings.updateContactOwnerOnReassign === true
      });
      this.toast(SAVED, "success");
      this.errorMessage = undefined;
    } catch (error) {
      this.toast(this.messageFrom(error), "error");
    } finally {
      this.isSaving = false;
    }
  }

  // ---------- nightly jobs ----------

  handleSchedule() {
    return this.runJobAction(scheduleJobs);
  }

  handleUnschedule() {
    return this.runJobAction(unscheduleJobs);
  }

  handleRunNow() {
    return this.runJobAction(runDailySyncNow, JOBS_STARTED);
  }

  async runJobAction(action, successMessage) {
    this.isJobBusy = true;
    try {
      this.jobs = await action();
      this.jobsLoaded = true;
      if (successMessage) {
        this.toast(successMessage, "success");
      }
    } catch (error) {
      this.toast(this.messageFrom(error), "error");
    } finally {
      this.isJobBusy = false;
    }
  }

  // ---------- remove OA (DEC-33) ----------

  async handleRemove(event) {
    const { id, name } = event.target.dataset;
    const confirmed = await LightningConfirm.open({
      message: REMOVE_CONFIRM.replace("{0}", name),
      variant: "header",
      theme: "warning",
      label: REMOVE
    });
    if (!confirmed) {
      return;
    }
    try {
      this.oas = await removeOA({ oaConfigId: id });
      this.toast(REMOVED.replace("{0}", name), "success");
    } catch (error) {
      this.toast(this.messageFrom(error), "error");
    }
  }

  // ---------- registration ----------

  handleChannelIdChange(event) {
    this.channelId = event.target.value;
  }

  handleChannelSecretChange(event) {
    this.channelSecret = event.target.value;
  }

  handleRepChange(event) {
    this.repId = event.detail.recordId;
  }

  async handleRegister() {
    if (!this.canRegister) {
      return;
    }
    this.isRegistering = true;
    try {
      const oa = await registerOA({
        channelId: this.channelId,
        channelSecret: this.channelSecret,
        repId: this.repId
      });
      this.toast(REGISTERED.replace("{0}", oa.name), "success");
      // The secret leaves the browser as soon as it is used.
      this.channelSecret = "";
      this.channelId = "";
      this.repId = undefined;
      await this.refresh();
    } catch (error) {
      this.toast(this.messageFrom(error), "error");
    } finally {
      this.isRegistering = false;
    }
  }

  // ---------- view model ----------

  get showSyncOff() {
    return this.jobsLoaded && this.jobs.dailySyncEnabled === false;
  }

  get isUnscheduleDisabled() {
    return this.isJobBusy || !this.jobs.scheduled;
  }

  get hasOAs() {
    return this.oas.length > 0;
  }

  get showNoOAs() {
    return !this.isLoading && !this.hasOAs;
  }

  get canRegister() {
    return !!(
      this.channelId &&
      this.channelId.trim() &&
      this.channelSecret &&
      this.repId &&
      !this.isRegistering
    );
  }

  get isRegisterDisabled() {
    return !this.canRegister;
  }

  get oaRows() {
    return this.oas.map((oa) => ({
      ...oa,
      statusVariant: oa.isActive ? "success" : "inverse",
      statusLabel: oa.isActive ? "Active" : "Inactive",
      isRemoved: oa.credentialStatus === "Removed",
      credentialLabel: this.credentialLabel(oa.credentialStatus),
      credentialClass:
        oa.credentialStatus === "Rejected" ? "slds-text-color_error" : ""
    }));
  }

  credentialLabel(status) {
    switch (status) {
      case "Valid":
        return CREDENTIAL_VALID;
      case "Rejected":
        return CREDENTIAL_REJECTED;
      case "Removed":
        return CREDENTIAL_REMOVED;
      default:
        return CREDENTIAL_UNCHECKED;
    }
  }

  toNumber(value) {
    if (value === null || value === undefined || value === "") {
      return null;
    }
    const parsed = Number(value);
    return Number.isNaN(parsed) ? null : parsed;
  }

  toast(message, variant) {
    this.dispatchEvent(new ShowToastEvent({ message, variant }));
  }

  messageFrom(error) {
    return error?.body?.message || error?.message || GENERIC_ERROR;
  }
}
