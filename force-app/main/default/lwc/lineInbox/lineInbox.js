import { LightningElement, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { NavigationMixin } from "lightning/navigation";

import getInbox from "@salesforce/apex/LineChatController.getInbox";
import linkToContact from "@salesforce/apex/LineChatController.linkToContact";
import unlinkConversation from "@salesforce/apex/LineChatController.unlinkConversation";

import TITLE from "@salesforce/label/c.LINE_Inbox_Title";
import UNREAD from "@salesforce/label/c.LINE_Inbox_Unread";
import UNLINKED from "@salesforce/label/c.LINE_Inbox_Unlinked";
import ALL from "@salesforce/label/c.LINE_Inbox_All";
import EMPTY from "@salesforce/label/c.LINE_Inbox_Empty";
import SELECT from "@salesforce/label/c.LINE_Inbox_Select";
import LOAD_MORE from "@salesforce/label/c.LINE_Inbox_Load_More";
import LINK_CONTACT from "@salesforce/label/c.LINE_Inbox_Link_Contact";
import LINK from "@salesforce/label/c.LINE_Inbox_Link";
import UNLINK from "@salesforce/label/c.LINE_Inbox_Unlink";
import LINKED from "@salesforce/label/c.LINE_Inbox_Linked";
import UNLINKED_DONE from "@salesforce/label/c.LINE_Inbox_Unlinked_Done";
import PLACEHOLDER_DELETED from "@salesforce/label/c.LINE_Inbox_Placeholder_Deleted";
import PLACEHOLDER_KEPT from "@salesforce/label/c.LINE_Inbox_Placeholder_Kept";
import GENERIC_ERROR from "@salesforce/label/c.LINE_Error_Generic";

// 02 §2: the inbox list refreshes every 30 s; the open chat polls on its own, faster.
const REFRESH_MS = 30000;

/**
 * The rep's LINE inbox (M6): their own conversations filtered by unread, not linked, or all, with the selected
 * conversation's chat and its Contact link on the same page.
 */
export default class LineInbox extends NavigationMixin(LightningElement) {
  filter = "unread";
  @track conversations = [];
  hasMore = false;
  isAdmin = false;
  isLoading = true;
  isLinking = false;
  selectedId;
  // The open conversation, kept even when a refresh drops it from the filtered list (e.g. read on the Unread tab).
  selected;
  pickedContactId;
  errorMessage;

  refreshTimer;
  visibilityHandler;

  labels = {
    title: TITLE,
    empty: EMPTY,
    select: SELECT,
    loadMore: LOAD_MORE,
    linkContact: LINK_CONTACT,
    link: LINK,
    unlink: UNLINK,
    unlinked: UNLINKED
  };

  connectedCallback() {
    this.visibilityHandler = () => this.onVisibilityChange();
    document.addEventListener("visibilitychange", this.visibilityHandler);
    this.load();
    this.startRefresh();
  }

  disconnectedCallback() {
    this.stopRefresh();
    if (this.visibilityHandler) {
      document.removeEventListener("visibilitychange", this.visibilityHandler);
      this.visibilityHandler = undefined;
    }
  }

  // ---------- loading ----------

  async load() {
    try {
      const page = await getInbox({
        filter: this.filter,
        beforeLastMessageAt: null,
        beforeId: null
      });
      this.conversations = page.conversations;
      this.hasMore = page.hasMore;
      this.isAdmin = page.isAdmin === true;
      this.errorMessage = undefined;
    } catch (error) {
      this.errorMessage = this.messageFrom(error);
    } finally {
      this.isLoading = false;
    }
  }

  async handleLoadMore() {
    const last = this.conversations[this.conversations.length - 1];
    if (!last) {
      return;
    }
    try {
      const page = await getInbox({
        filter: this.filter,
        beforeLastMessageAt: last.lastMessageAt,
        beforeId: last.id
      });
      const known = new Set(this.conversations.map((c) => c.id));
      this.conversations = [
        ...this.conversations,
        ...page.conversations.filter((c) => !known.has(c.id))
      ];
      this.hasMore = page.hasMore;
    } catch (error) {
      this.errorMessage = this.messageFrom(error);
    }
  }

  startRefresh() {
    this.stopRefresh();
    if (document.visibilityState !== "visible") {
      return;
    }
    // Polling is the agreed refresh mechanism (D7); cleared on hide and on disconnect.
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.refreshTimer = setInterval(() => this.load(), REFRESH_MS);
  }

  stopRefresh() {
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = undefined;
    }
  }

  onVisibilityChange() {
    if (document.visibilityState === "visible") {
      this.load();
      this.startRefresh();
    } else {
      this.stopRefresh();
    }
  }

  // ---------- list ----------

  handleFilterChange(event) {
    this.filter = event.detail.value;
    this.isLoading = true;
    this.load();
  }

  handleSelect(event) {
    this.selectedId = event.currentTarget.dataset.id;
    this.selected = this.conversations.find((c) => c.id === this.selectedId);
    this.pickedContactId = undefined;
  }

  handleRead(event) {
    const id = event.detail.conversationId;
    this.conversations = this.conversations.map((c) => {
      return c.id === id ? { ...c, unreadCount: 0 } : c;
    });
  }

  // ---------- linking (03 §5 rules 3–4, DEC-34) ----------

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
        conversationId: this.selectedId,
        contactId: this.pickedContactId
      });
      this.replaceConversation(result.conversation);
      this.pickedContactId = undefined;
      this.toast(
        LINKED.replace("{0}", result.conversation.contactName),
        "success"
      );
      if (result.placeholderDeleted) {
        this.toast(PLACEHOLDER_DELETED, "info");
      } else if (result.placeholderKept) {
        this.toast(PLACEHOLDER_KEPT, "warning");
      }
    } catch (error) {
      this.toast(this.messageFrom(error), "error");
    } finally {
      this.isLinking = false;
    }
  }

  async handleUnlink() {
    try {
      const conversation = await unlinkConversation({
        conversationId: this.selectedId
      });
      this.replaceConversation(conversation);
      this.toast(UNLINKED_DONE, "success");
    } catch (error) {
      this.toast(this.messageFrom(error), "error");
    }
  }

  handleOpenContact() {
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId: this.selectedConversation.contactId,
        objectApiName: "Contact",
        actionName: "view"
      }
    });
  }

  replaceConversation(updated) {
    if (!updated) {
      return;
    }
    this.conversations = this.conversations.map((c) => {
      return c.id === updated.id ? { ...c, ...updated } : c;
    });
    if (this.selected && this.selected.id === updated.id) {
      this.selected = { ...this.selected, ...updated };
    }
  }

  // ---------- view model ----------

  get filterOptions() {
    return [
      { label: UNREAD, value: "unread" },
      { label: UNLINKED, value: "unlinked" },
      { label: ALL, value: "all" }
    ];
  }

  get selectedConversation() {
    return (
      this.conversations.find((c) => c.id === this.selectedId) || this.selected
    );
  }

  get showEmpty() {
    return !this.isLoading && this.conversations.length === 0;
  }

  get isLinkDisabled() {
    return !this.pickedContactId || this.isLinking;
  }

  get items() {
    return this.conversations.map((c) => {
      const isSelected = c.id === this.selectedId;
      return {
        ...c,
        hasUnread: c.unreadCount > 0,
        contactLabel: c.contactName || UNLINKED,
        ariaPressed: isSelected ? "true" : "false",
        buttonClass: isSelected
          ? "slds-button line-inbox-item line-inbox-item_selected"
          : "slds-button line-inbox-item"
      };
    });
  }

  // ---------- helpers ----------

  toast(message, variant) {
    this.dispatchEvent(new ShowToastEvent({ message, variant }));
  }

  messageFrom(error) {
    return error?.body?.message || GENERIC_ERROR;
  }
}
