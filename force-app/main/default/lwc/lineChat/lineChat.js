import { LightningElement, api, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";

import getConversations from "@salesforce/apex/LineChatController.getConversations";
import getMessages from "@salesforce/apex/LineChatController.getMessages";
import getMessagesSince from "@salesforce/apex/LineChatController.getMessagesSince";
import markRead from "@salesforce/apex/LineChatController.markRead";
import sendText from "@salesforce/apex/LineChatController.sendText";
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
import GENERIC_ERROR from "@salesforce/label/c.LINE_Error_Generic";
import PREVIEW_IMAGE from "@salesforce/label/c.LINE_Preview_Image";
import PREVIEW_VIDEO from "@salesforce/label/c.LINE_Preview_Video";
import PREVIEW_AUDIO from "@salesforce/label/c.LINE_Preview_Audio";
import PREVIEW_STICKER from "@salesforce/label/c.LINE_Preview_Sticker";
import PREVIEW_UNSUPPORTED from "@salesforce/label/c.LINE_Preview_Unsupported";

const MAX_TEXT_LENGTH = 5000;
const DEFAULT_POLL_SECONDS = 5;
// Within this many pixels of the top counts as "at the top" on trackpads and touch screens.
const SCROLL_TOP_THRESHOLD_PX = 40;

/**
 * Chat panel for the Contact record page: history, polling and sending text.
 * Stickers show as pictures from LINE's sticker CDN (DEC-32), falling back to a placeholder if one won't load.
 * Media and the invite flow arrive in M6/M7; other non-text messages show as placeholders for now.
 */
export default class LineChat extends LightningElement {
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
    unfollowed: UNFOLLOWED
  };

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
    try {
      this.conversations = await getConversations({ contactId: this.recordId });
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
    } catch (error) {
      // A failed poll is transient; the next one may work, so don't shout at the rep.
      this.stopPolling();
      this.errorMessage = this.messageFrom(error);
    }
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

  handleConversationSelect(event) {
    const conversationId = event.currentTarget.dataset.id;
    if (conversationId !== this.selectedConversationId) {
      this.selectConversation(conversationId);
    }
  }

  handleInvite() {
    // Wired to the QR invite modal in M6.
    this.dispatchEvent(new CustomEvent("invite"));
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

  get isSendDisabled() {
    return (
      this.isSending || !(this.draft || "").trim() || this.showUnfollowedBanner
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
        placeholder: isText || showSticker ? undefined : this.placeholderFor(m),
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
