import { LightningElement, api, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { NavigationMixin } from "lightning/navigation";
import LineInvite from "c/lineInvite";

import getConversations from "@salesforce/apex/LineChatController.getConversations";
import linkToContact from "@salesforce/apex/LineChatController.linkToContact";
import unlinkConversation from "@salesforce/apex/LineChatController.unlinkConversation";
import getMessages from "@salesforce/apex/LineChatController.getMessages";
import getMessagesSince from "@salesforce/apex/LineChatController.getMessagesSince";
import markRead from "@salesforce/apex/LineChatController.markRead";
import sendText from "@salesforce/apex/LineChatController.sendText";
import prepareFile from "@salesforce/apex/LineChatController.prepareFile";
import sendFile from "@salesforce/apex/LineChatController.sendFile";
import sendSticker from "@salesforce/apex/LineChatController.sendSticker";
import getStickerCatalog from "@salesforce/apex/LineChatController.getStickerCatalog";
import getPollIntervalSeconds from "@salesforce/apex/LineChatController.getPollIntervalSeconds";

import TITLE from "@salesforce/label/c.LINE_Chat_Title";
import NO_CONVERSATIONS from "@salesforce/label/c.LINE_Chat_No_Conversations";
import INVITE from "@salesforce/label/c.LINE_Chat_Invite";
import NO_MESSAGES from "@salesforce/label/c.LINE_Chat_No_Messages";
import INPUT_PLACEHOLDER from "@salesforce/label/c.LINE_Chat_Input_Placeholder";
import SEND from "@salesforce/label/c.LINE_Chat_Send";
import LOAD_OLDER from "@salesforce/label/c.LINE_Chat_Load_Older";
import SEND_HINT from "@salesforce/label/c.LINE_Chat_Send_Hint";
import FAILED_BADGE from "@salesforce/label/c.LINE_Chat_Failed_Badge";
import UNFOLLOWED from "@salesforce/label/c.LINE_Chat_Unfollowed";
import NOT_ASSIGNED_REP from "@salesforce/label/c.LINE_Chat_Not_Assigned_Rep";
import GENERIC_ERROR from "@salesforce/label/c.LINE_Error_Generic";
import PREVIEW_IMAGE from "@salesforce/label/c.LINE_Preview_Image";
import PREVIEW_VIDEO from "@salesforce/label/c.LINE_Preview_Video";
import PREVIEW_AUDIO from "@salesforce/label/c.LINE_Preview_Audio";
import PREVIEW_STICKER from "@salesforce/label/c.LINE_Preview_Sticker";
import PREVIEW_UNSUPPORTED from "@salesforce/label/c.LINE_Preview_Unsupported";
import FILE_DOWNLOADING from "@salesforce/label/c.LINE_File_Downloading";
import FILE_TOO_LARGE from "@salesforce/label/c.LINE_File_Too_Large";
import FILE_DOWNLOAD_FAILED from "@salesforce/label/c.LINE_File_Download_Failed";
import FILE_OPEN from "@salesforce/label/c.LINE_File_Open";
import ATTACH from "@salesforce/label/c.LINE_Chat_Attach";
import PHOTO from "@salesforce/label/c.LINE_Chat_Photo";
import STICKERS from "@salesforce/label/c.LINE_Chat_Stickers";
import LINK_ACTION from "@salesforce/label/c.LINE_Link_Action";
import LINK_CONTACT_LABEL from "@salesforce/label/c.LINE_Link_Contact_Label";
import LINK_BUTTON from "@salesforce/label/c.LINE_Link_Button";
import LINK_CANCEL from "@salesforce/label/c.LINE_Link_Cancel";
import UNLINK_BUTTON from "@salesforce/label/c.LINE_Unlink_Button";
import LINK_DONE from "@salesforce/label/c.LINE_Link_Done";
import UNLINK_DONE from "@salesforce/label/c.LINE_Unlink_Done";
import PLACEHOLDER_DELETED from "@salesforce/label/c.LINE_Link_Placeholder_Deleted";
import PLACEHOLDER_KEPT from "@salesforce/label/c.LINE_Link_Placeholder_Kept";

const MAX_TEXT_LENGTH = 5000;
const DEFAULT_POLL_SECONDS = 2;
// Within this many pixels of the top counts as "at the top" on trackpads and touch screens.
const SCROLL_TOP_THRESHOLD_PX = 40;
// Salesforce's own thumbnail of a file version (M7). A relative platform path, the same in every org.
const THUMBNAIL_PATH =
  "/sfc/servlet.shepherd/version/renditionDownload?rendition=THUMB720BY480&versionId=";
// Inbound files still being fetched from LINE; the poll picks up the finished file.
const STATUS_TEXT = {
  Downloading: FILE_DOWNLOADING,
  "Too Large": FILE_TOO_LARGE,
  "Download Failed": FILE_DOWNLOAD_FAILED
};

/**
 * Chat panel for the Contact record page: history, polling and sending text.
 * Stickers show as pictures from LINE's sticker CDN (DEC-32), falling back to a placeholder if one won't load.
 * With no conversation yet, *Invite via LINE* opens the QR invite (`lineInvite`). Media arrives in M7; other non-text
 * messages show as placeholders for now.
 */
export default class LineChat extends NavigationMixin(LightningElement) {
  @api recordId;

  // Sticker pictures that failed to load; those show the placeholder instead.
  brokenStickerIds = [];

  @track conversations = [];
  @track messages = [];
  selectedConversationId;
  hasMore = false;
  isLoading = true;
  isSending = false;
  isLoadingOlder = false;
  draft = "";
  errorMessage;

  scrollAnchor;
  shouldScrollToBottom = false;
  pollIntervalMs = DEFAULT_POLL_SECONDS * 1000;
  pollTimer;
  visibilityHandler;

  labels = {
    sticker: PREVIEW_STICKER,
    title: TITLE,
    noConversations: NO_CONVERSATIONS,
    invite: INVITE,
    noMessages: NO_MESSAGES,
    inputPlaceholder: INPUT_PLACEHOLDER,
    send: SEND,
    loadOlder: LOAD_OLDER,
    sendHint: SEND_HINT,
    unfollowed: UNFOLLOWED,
    notAssignedRep: NOT_ASSIGNED_REP,
    openFile: FILE_OPEN,
    attach: ATTACH,
    photo: PHOTO,
    stickers: STICKERS,
    linkAction: LINK_ACTION,
    linkContact: LINK_CONTACT_LABEL,
    link: LINK_BUTTON,
    cancel: LINK_CANCEL,
    unlink: UNLINK_BUTTON
  };

  // Linking from the panel (DEC-44): move this chat to the right Contact, e.g. off a Contact LINE Connect created.
  showLinkPanel = false;

  // Composer trays (DEC-44): "files", "photos" or "stickers"; one open at a time.
  tray;
  stickerCatalog;
  activePackageId;
  pickedContactId;
  isLinking = false;

  async connectedCallback() {
    this.visibilityHandler = () => this.onVisibilityChange();
    document.addEventListener("visibilitychange", this.visibilityHandler);
    await this.loadPollInterval();
    await this.loadConversations();
  }

  disconnectedCallback() {
    this.stopPolling();
    if (this.visibilityHandler) {
      document.removeEventListener("visibilitychange", this.visibilityHandler);
      this.visibilityHandler = undefined;
    }
  }

  // ---------- loading ----------

  async loadPollInterval() {
    try {
      const seconds = await getPollIntervalSeconds();
      if (seconds > 0) {
        this.pollIntervalMs = seconds * 1000;
      }
    } catch {
      // A missing setting is not worth blocking the panel; the default applies.
      this.pollIntervalMs = DEFAULT_POLL_SECONDS * 1000;
    }
  }

  async loadConversations() {
    this.isLoading = true;
    this.stopPolling();
    try {
      this.conversations = await getConversations({
        contactId: this.recordId
      });
      if (this.conversations.length) {
        await this.selectConversation(this.conversations[0].id);
      }
      this.errorMessage = undefined;
    } catch (error) {
      this.errorMessage = this.messageFrom(error);
    } finally {
      this.isLoading = false;
    }
  }

  async selectConversation(conversationId) {
    this.selectedConversationId = conversationId;
    this.messages = [];
    this.hasMore = false;
    await this.loadLatestMessages();
    await this.markConversationRead();
    this.startPolling();
  }

  async loadLatestMessages() {
    try {
      const page = await getMessages({
        conversationId: this.selectedConversationId,
        beforeSentAt: null,
        beforeId: null,
        pageSize: null
      });
      this.messages = page.messages;
      this.hasMore = page.hasMore;
      this.shouldScrollToBottom = true;
      this.errorMessage = undefined;
    } catch (error) {
      this.errorMessage = this.messageFrom(error);
    }
  }

  /**
   * Loads the page before the oldest message held. Triggered by scrolling to the top of the list, and by the
   * button above it, which keeps the same behaviour reachable from the keyboard and a screen reader.
   */
  async handleLoadOlder() {
    if (!this.messages.length || this.isLoadingOlder || !this.hasMore) {
      return;
    }
    this.isLoadingOlder = true;
    const oldest = this.messages[0];
    // Remember the current height so the view can stay on the same message after older ones are prepended.
    const list = this.listElement;
    this.scrollAnchor = list
      ? { previousHeight: list.scrollHeight, previousTop: list.scrollTop }
      : undefined;
    try {
      const page = await getMessages({
        conversationId: this.selectedConversationId,
        beforeSentAt: oldest.sentAt,
        beforeId: oldest.id,
        pageSize: null
      });
      this.messages = [...page.messages, ...this.messages];
      this.hasMore = page.hasMore;
    } catch (error) {
      this.scrollAnchor = undefined;
      this.errorMessage = this.messageFrom(error);
    } finally {
      this.isLoadingOlder = false;
    }
  }

  /**
   * Near the top of the list means "show me what came before".
   * @param {Event} event scroll event of the message list
   */
  handleScroll(event) {
    if (event.target.scrollTop <= SCROLL_TOP_THRESHOLD_PX) {
      this.handleLoadOlder();
    }
  }

  get listElement() {
    return this.template.querySelector(".line-messages");
  }

  renderedCallback() {
    const list = this.listElement;
    if (!list) {
      return;
    }
    if (this.scrollAnchor) {
      // Keep the message the rep was reading in place, instead of jumping to the new top.
      const { previousHeight, previousTop } = this.scrollAnchor;
      list.scrollTop = list.scrollHeight - previousHeight + previousTop;
      this.scrollAnchor = undefined;
      return;
    }
    if (this.shouldScrollToBottom) {
      list.scrollTop = list.scrollHeight;
      this.shouldScrollToBottom = false;
    }
  }

  // ---------- polling (D7) ----------

  startPolling() {
    this.stopPolling();
    if (
      !this.selectedConversationId ||
      document.visibilityState !== "visible"
    ) {
      return;
    }
    // Polling is the agreed refresh mechanism (D7); it is cleared on hide and on disconnect.
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.pollTimer = setInterval(() => this.poll(), this.pollIntervalMs);
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = undefined;
    }
  }

  onVisibilityChange() {
    // Polling only runs while the tab is visible, so a forgotten tab costs nothing.
    if (document.visibilityState === "visible") {
      this.poll();
      this.startPolling();
    } else {
      this.stopPolling();
    }
  }

  async poll() {
    if (!this.selectedConversationId) {
      return;
    }
    const newest = this.messages.length
      ? this.messages[this.messages.length - 1]
      : undefined;
    try {
      const incoming = await getMessagesSince({
        conversationId: this.selectedConversationId,
        afterSentAt: newest ? newest.sentAt : null,
        afterId: newest ? newest.id : null
      });
      if (incoming && incoming.length) {
        const known = new Set(this.messages.map((m) => m.id));
        const added = incoming.filter((m) => !known.has(m.id));
        if (added.length) {
          this.messages = [...this.messages, ...added];
          this.shouldScrollToBottom = true;
          if (added.some((m) => !m.isOutbound)) {
            await this.markConversationRead();
          }
        }
      }
      await this.refreshPendingFiles();
    } catch (error) {
      // A failed poll is transient; the next one may work, so don't shout at the rep.
      this.stopPolling();
      this.errorMessage = this.messageFrom(error);
    }
  }

  // A customer's file arrives as "Downloading" and is saved a few seconds later (M7). New-message polling never
  // re-reads it, so while any is pending the newest page is fetched again and those messages are swapped in.
  async refreshPendingFiles() {
    if (!this.messages.some((m) => m.status === "Downloading")) {
      return;
    }
    const page = await getMessages({
      conversationId: this.selectedConversationId,
      beforeSentAt: null,
      beforeId: null,
      pageSize: null
    });
    const fresh = new Map(page.messages.map((m) => [m.id, m]));
    this.messages = this.messages.map((m) => fresh.get(m.id) || m);
  }

  async markConversationRead() {
    try {
      await markRead({ conversationId: this.selectedConversationId });
      this.conversations = this.conversations.map((c) => {
        return c.id === this.selectedConversationId
          ? { ...c, unreadCount: 0 }
          : c;
      });
    } catch {
      // Not worth interrupting the rep: the count clears on the next read.
    }
  }

  // ---------- sending ----------

  handleDraftChange(event) {
    this.draft = event.target.value;
  }

  handleKeyDown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.handleSend();
    }
  }

  async handleSend() {
    const text = (this.draft || "").trim();
    if (!text || this.isSending || !this.selectedConversationId) {
      return;
    }
    this.isSending = true;
    try {
      const sent = await sendText({
        conversationId: this.selectedConversationId,
        text
      });
      this.messages = [...this.messages, sent];
      this.shouldScrollToBottom = true;
      this.draft = "";
      this.errorMessage = undefined;
    } catch (error) {
      this.dispatchEvent(
        new ShowToastEvent({
          message: this.messageFrom(error),
          variant: "error"
        })
      );
    } finally {
      this.isSending = false;
    }
  }

  /**
   * M7: the upload already saved the file on the conversation; give it a public link, then send it. Two calls,
   * because the link is a write and LINE's push has to come before any write in a transaction.
   * @param {CustomEvent} event uploadfinished from lightning-file-upload
   */
  async handleUploadFinished(event) {
    const files = event.detail.files || [];
    this.isSending = true;
    try {
      for (const file of files) {
        const ids = {
          conversationId: this.selectedConversationId,
          contentDocumentId: file.documentId
        };
        // eslint-disable-next-line no-await-in-loop
        await prepareFile(ids);
        // eslint-disable-next-line no-await-in-loop
        const sent = await sendFile(ids);
        this.messages = [...this.messages, sent];
        this.shouldScrollToBottom = true;
      }
      this.tray = undefined;
    } catch (error) {
      this.dispatchEvent(
        new ShowToastEvent({
          message: this.messageFrom(error),
          variant: "error"
        })
      );
    } finally {
      this.isSending = false;
    }
  }

  // ---------- composer trays (DEC-44) ----------

  handleOpenFiles() {
    this.tray = this.tray === "files" ? undefined : "files";
  }

  handleOpenPhotos() {
    this.tray = this.tray === "photos" ? undefined : "photos";
  }

  async handleToggleStickers() {
    if (this.tray === "stickers") {
      this.tray = undefined;
      return;
    }
    this.tray = "stickers";
    if (!this.stickerCatalog) {
      try {
        this.stickerCatalog = await getStickerCatalog();
        this.activePackageId = this.stickerCatalog[0]?.packageId;
      } catch (error) {
        this.tray = undefined;
        this.toast(this.messageFrom(error), "error");
      }
    }
  }

  handleStickerPack(event) {
    this.activePackageId = event.currentTarget.dataset.package;
  }

  async handleStickerSend(event) {
    const { package: packageId, sticker: stickerId } =
      event.currentTarget.dataset;
    if (this.isSending) {
      return;
    }
    this.isSending = true;
    try {
      const sent = await sendSticker({
        conversationId: this.selectedConversationId,
        packageId,
        stickerId
      });
      this.messages = [...this.messages, sent];
      this.shouldScrollToBottom = true;
      this.tray = undefined;
    } catch (error) {
      this.toast(this.messageFrom(error), "error");
    } finally {
      this.isSending = false;
    }
  }

  get showUploadTray() {
    return this.tray === "files" || this.tray === "photos";
  }

  get showStickerTray() {
    return this.tray === "stickers" && !!this.stickerCatalog;
  }

  get uploadLabel() {
    return this.tray === "photos" ? PHOTO : ATTACH;
  }

  // Photos only for the photo button; on a phone the picker also offers the camera.
  get uploadAccept() {
    return this.tray === "photos"
      ? [".jpg", ".jpeg", ".png", ".gif", ".heic"]
      : undefined;
  }

  get stickerPacks() {
    return (this.stickerCatalog || []).map((pack) => ({
      packageId: pack.packageId,
      coverUrl: pack.stickers[0]?.url,
      tabClass:
        pack.packageId === this.activePackageId
          ? "slds-button line-sticker-pack line-sticker-pack_active"
          : "slds-button line-sticker-pack"
    }));
  }

  get activeStickers() {
    const pack = (this.stickerCatalog || []).find(
      (p) => p.packageId === this.activePackageId
    );
    return pack ? pack.stickers : [];
  }

  get isUploadDisabled() {
    return (
      this.isSending || this.showUnfollowedBanner || this.showReadOnlyNotice
    );
  }

  // ---------- linking (03 §5 rules 3–4, DEC-34, DEC-44) ----------

  handleToggleLink() {
    this.showLinkPanel = !this.showLinkPanel;
    this.pickedContactId = undefined;
  }

  handleContactPick(event) {
    this.pickedContactId = event.detail.recordId;
  }

  async handleLink() {
    if (this.isLinkDisabled) {
      return;
    }
    this.isLinking = true;
    try {
      const result = await linkToContact({
        conversationId: this.selectedConversationId,
        contactId: this.pickedContactId
      });
      this.toast(
        LINK_DONE.replace("{0}", result.conversation.contactName),
        "success"
      );
      if (result.placeholderDeleted) {
        this.toast(PLACEHOLDER_DELETED, "info");
      } else if (result.placeholderKept) {
        this.toast(PLACEHOLDER_KEPT, "warning");
      }
      this.showLinkPanel = false;
      // The chat now lives on the chosen Contact; this one may even have been the placeholder that was removed.
      this[NavigationMixin.Navigate]({
        type: "standard__recordPage",
        attributes: {
          recordId: result.conversation.contactId,
          objectApiName: "Contact",
          actionName: "view"
        }
      });
    } catch (error) {
      this.toast(this.messageFrom(error), "error");
    } finally {
      this.isLinking = false;
    }
  }

  async handleUnlink() {
    try {
      await unlinkConversation({ conversationId: this.selectedConversationId });
      this.toast(UNLINK_DONE, "success");
      this.showLinkPanel = false;
      await this.loadConversations();
    } catch (error) {
      this.toast(this.messageFrom(error), "error");
    }
  }

  get isLinkDisabled() {
    return !this.pickedContactId || this.isLinking;
  }

  get canUnlink() {
    return this.selectedConversation?.canUnlink === true;
  }

  toast(message, variant) {
    this.dispatchEvent(new ShowToastEvent({ message, variant }));
  }

  handleConversationSelect(event) {
    const conversationId = event.currentTarget.dataset.id;
    if (conversationId !== this.selectedConversationId) {
      this.selectConversation(conversationId);
    }
  }

  // QR invite (M6): the customer's first message with the code links their chat to this Contact.
  async handleInvite() {
    await LineInvite.open({
      size: "small",
      label: INVITE,
      contactId: this.recordId
    });
    // The customer may already have scanned and sent the code while the modal was open.
    await this.loadConversations();
  }

  // ---------- view model ----------

  get selectedConversation() {
    return this.conversations.find((c) => c.id === this.selectedConversationId);
  }

  get hasConversations() {
    return this.conversations.length > 0;
  }

  get showEmptyState() {
    return !this.isLoading && !this.hasConversations;
  }

  get hasMultipleConversations() {
    return this.conversations.length > 1;
  }

  get showUnfollowedBanner() {
    const conversation = this.selectedConversation;
    return !!conversation && conversation.status === "Unfollowed";
  }

  // DEC-37: only the OA's assigned rep (or the fallback owner of an inactive OA) may reply; others can read.
  get showReadOnlyNotice() {
    const conversation = this.selectedConversation;
    return !!conversation && conversation.canSend !== true;
  }

  get isSendDisabled() {
    return (
      this.isSending ||
      !(this.draft || "").trim() ||
      this.showUnfollowedBanner ||
      this.showReadOnlyNotice
    );
  }

  get maxLength() {
    return MAX_TEXT_LENGTH;
  }

  get hasMessages() {
    return this.messages.length > 0;
  }

  get showNoMessages() {
    return !this.isLoading && this.hasConversations && !this.hasMessages;
  }

  /** Messages shaped for the template: text stays text, everything else gets a placeholder. */
  get messageViews() {
    return this.messages.map((m) => {
      const isText = m.messageType === "text";
      const showSticker =
        m.messageType === "sticker" &&
        !!m.stickerUrl &&
        !this.brokenStickerIds.includes(m.id);
      // M7: a saved image shows its thumbnail; any other saved file shows as a chip that opens the preview.
      const showImage = m.messageType === "image" && !!m.contentVersionId;
      const showFile = !showImage && !!m.contentDocumentId;
      const statusText = STATUS_TEXT[m.status];
      return {
        ...m,
        key: m.id,
        bubbleClass: showSticker
          ? "line-bubble line-bubble_sticker slds-p-around_x-small"
          : m.isOutbound
            ? "line-bubble line-bubble_outbound slds-p-around_x-small"
            : "line-bubble line-bubble_inbound slds-p-around_x-small",
        rowClass: m.isOutbound
          ? "slds-grid slds-grid_align-end slds-m-bottom_x-small"
          : "slds-grid slds-m-bottom_x-small",
        isText,
        showSticker,
        showImage,
        showFile,
        thumbnailUrl: showImage
          ? THUMBNAIL_PATH + m.contentVersionId
          : undefined,
        fileLabel: m.fileName || this.placeholderFor(m),
        statusText,
        placeholder:
          isText || showSticker || showImage || showFile
            ? undefined
            : this.placeholderFor(m),
        isFailed: m.status === "Failed",
        failedLabel: FAILED_BADGE,
        failedDetail: m.errorMessage
      };
    });
  }

  // LINE's sticker CDN is not an official API (DEC-32): if a picture won't load, fall back to "[Sticker]".
  handleStickerError(event) {
    const id = event.target.dataset.id;
    if (id && !this.brokenStickerIds.includes(id)) {
      this.brokenStickerIds = [...this.brokenStickerIds, id];
    }
  }

  handleOpenFile(event) {
    this[NavigationMixin.Navigate]({
      type: "standard__namedPage",
      attributes: { pageName: "filePreview" },
      state: { selectedRecordId: event.currentTarget.dataset.documentId }
    });
  }

  placeholderFor(message) {
    switch (message.messageType) {
      case "image":
        return PREVIEW_IMAGE;
      case "video":
        return PREVIEW_VIDEO;
      case "audio":
        return PREVIEW_AUDIO;
      case "sticker":
        return PREVIEW_STICKER;
      case "file":
        return message.fileName || PREVIEW_UNSUPPORTED;
      case "location":
        return message.location || PREVIEW_UNSUPPORTED;
      default:
        return PREVIEW_UNSUPPORTED;
    }
  }

  messageFrom(error) {
    return error?.body?.message || error?.message || GENERIC_ERROR;
  }
}
