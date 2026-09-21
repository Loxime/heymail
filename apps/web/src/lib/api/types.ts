export interface DashboardPeriod {
  from: string
  to: string
}

export interface DashboardMessages {
  total: number
  queued: number
  readyForSubmission: number
  submitting: number
  submissionUncertain: number
  submitted: number
}

export interface DashboardDelivery {
  delivered: number
  tempfail: number
  bounced: number
  terminalOutcomes: number
  deliveryRate: number
  bounceRate: number
}

export interface DashboardActivityDay {
  date: string
  submitted: number
  tempfail: number
  delivered: number
  bounced: number
}

export interface DashboardRecipientDomain {
  domain: string | null
  delivered: number
  tempfail: number
  bounced: number
  terminalOutcomes: number
  deliveryRate: number
  bounceRate: number
}

export interface DashboardResponse {
  period: DashboardPeriod
  messages: DashboardMessages
  delivery: DashboardDelivery
  recipientDomains: DashboardRecipientDomain[]
  activity: DashboardActivityDay[]
}

export interface DeliverySummary {
  delivered: number
  tempfail: number
  bounced: number
}

export interface MessageListItem {
  messageId: number
  status: string
  createdAt: string
  readyForSubmissionAt: string | null
  submittingAt: string | null
  submissionUncertainAt: string | null
  submittedAt: string | null
  deliverySummary: DeliverySummary
}

export interface MessageListResponse {
  items: MessageListItem[]
  nextCursor: string | null
}

export interface MessageEvent {
  type: string
  occurredAt: string
  recipientHash: string | null
  smtpStatus: string | null
  detail: string | null
}

export interface MessageDetailResponse {
  messageId: number
  status: string
  createdAt: string
  readyForSubmissionAt: string | null
  submittingAt: string | null
  submissionUncertainAt: string | null
  submittedAt: string | null
  deliverySummary: DeliverySummary
  events: MessageEvent[]
}

export interface DnsRecord {
  type: string
  name: string
  value: string
}

export interface DomainDkim {
  ready: boolean
  selector: string | null
  type: string
  name: string | null
  value: string | null
  provisionedAt: string | null
}

export interface SendingDomain {
  id: number
  domain: string
  status: 'pending' | 'verified' | 'disabled'
  verification: DnsRecord
  dkim: DomainDkim
  createdAt: string
  verificationCheckedAt: string | null
  verifiedAt: string | null
  disabledAt: string | null
}

export interface SendingDomainListResponse {
  items: SendingDomain[]
}

export interface SendingDomainCreateResponse
  extends SendingDomain {
  replayed: boolean
}

export interface DomainVerificationResponse
  extends SendingDomain {
  verificationQueued: boolean
}

export interface DomainDkimProvisionResponse
  extends SendingDomain {
  dkimProvisioningQueued: boolean
}

export interface SenderIdentity {
  id: number
  email: string
  domain: string
  authorized: boolean
  createdAt: string
}

export interface SenderIdentityListResponse {
  items: SenderIdentity[]
}

export interface SenderIdentityCreateResponse
  extends SenderIdentity {
  replayed: boolean
}

export type WebhookEventType =
  | 'delivered'
  | 'tempfail'
  | 'bounced'

export interface WebhookEndpoint {
  webhookId: string
  url: string
  events: WebhookEventType[]
  enabled: boolean
  createdAt: string
}

export interface WebhookListResponse {
  items: WebhookEndpoint[]
}

export interface WebhookCreateResponse
  extends WebhookEndpoint {
  secret: string
}

export interface EmailAddressPayload {
  email: string
  name?: string
}

export interface SendMessagePayload {
  from: EmailAddressPayload
  to: EmailAddressPayload[]
  subject: string
  text?: string
  html?: string
  replyTo?: EmailAddressPayload
}

export interface SendMessageResponse {
  messageId: number
  status: string
  replayed: boolean
}


export interface ConsoleUser {
  id: number
  email: string
  firstName: string
  lastName: string
}

export interface ConsoleSessionResponse {
  user: ConsoleUser
}

export interface ConsoleFavoriteContact {
  id: number
  email: string
  name: string | null
  createdAt: string
}

export interface ConsoleApiCredential {
  id: number
  apiKey: string
  fingerprint: string
  label: string
  createdAt: string
  lastUsedAt: string | null
  revokedAt: string | null
}

export interface ConsoleApiCredentialListResponse {
  items: ConsoleApiCredential[]
}

export interface ConsoleApiCredentialSecretResponse {
  credential: ConsoleApiCredential
  secret: string
}

export type ConsoleVisualEmailAlignment =
  | 'left'
  | 'center'
  | 'right'

export interface ConsoleVisualEmailTextBlock {
  id: string
  type: 'text'
  text: string
  align: ConsoleVisualEmailAlignment
}

export interface ConsoleVisualEmailImageBlock {
  id: string
  type: 'image'
  url: string
  alt: string
  align: ConsoleVisualEmailAlignment
}

export interface ConsoleVisualEmailButtonBlock {
  id: string
  type: 'button'
  label: string
  url: string
  align: ConsoleVisualEmailAlignment
}

export interface ConsoleVisualEmailColumnsBlock {
  id: string
  type: 'columns'
  columns: [
    {
      text: string
      align: ConsoleVisualEmailAlignment
    },
    {
      text: string
      align: ConsoleVisualEmailAlignment
    },
  ]
}

export type ConsoleVisualEmailBlock =
  | ConsoleVisualEmailTextBlock
  | ConsoleVisualEmailImageBlock
  | ConsoleVisualEmailButtonBlock
  | ConsoleVisualEmailColumnsBlock

export interface ConsoleVisualEmailDocument {
  version: 1
  blocks: ConsoleVisualEmailBlock[]
}

export interface ConsoleEmailTemplate {
  id: number
  name: string
  version: number
  subject: string
  text: string | null
  html: string | null
  visual: ConsoleVisualEmailDocument | null
  variables: string[]
  createdAt: string
  updatedAt: string
  versionCreatedAt: string
}

export interface ConsoleEmailTemplateListResponse {
  items: ConsoleEmailTemplate[]
}

export interface ConsoleEmailTemplateVersion {
  id: number
  version: number
  subject: string
  text: string | null
  html: string | null
  visual: ConsoleVisualEmailDocument | null
  variables: string[]
  createdAt: string
}

export interface ConsoleEmailTemplateHistoryResponse {
  items: ConsoleEmailTemplateVersion[]
}

export interface ConsoleEmailTemplateRenderResponse {
  templateId: number
  name: string
  version: number
  subject: string
  text: string | null
  html: string | null
}

export type ConsoleContactCustomFieldValue =
  | string
  | number
  | boolean
  | null

export interface ConsoleContact {
  id: number
  email: string
  name: string | null
  customFields: Record<
    string,
    ConsoleContactCustomFieldValue
  >
  tags: string[]
  listIds: number[]
  createdAt: string
  updatedAt: string
}

export interface ConsoleContactListResponse {
  items: ConsoleContact[]
}

export interface ConsoleContactListResponseItem {
  id: number
  name: string
  contactCount: number
  createdAt: string
  updatedAt: string
}

export interface ConsoleContactListListResponse {
  items: ConsoleContactListResponseItem[]
}

export interface ConsoleContactTag {
  id: number
  name: string
  contactCount: number
  createdAt: string
}

export interface ConsoleContactTagListResponse {
  items: ConsoleContactTag[]
}

export interface ConsoleContactImportResponse {
  rows: number
  created: number
  updated: number
}

export type ConsoleCampaignStatus =
  | 'draft'
  | 'scheduled'
  | 'ready'
  | 'processing'
  | 'paused'
  | 'completed'
  | 'cancelled'

export interface ConsoleCampaign {
  id: number
  name: string
  senderId: number | null
  templateId: number | null
  listId: number | null
  status: ConsoleCampaignStatus
  trackingEnabled: boolean
  scheduledFor: string | null
  snapshotAt: string | null
  templateVersion: number | null
  recipientCount: number
  processedCount: number
  pausedAt: string | null
  completedAt: string | null
  lastError: string | null
  createdAt: string
  updatedAt: string
}

export interface ConsoleCampaignListResponse {
  items: ConsoleCampaign[]
}

export interface ConsoleCampaignTrackingStats {
  campaignId: number
  trackingEnabled: boolean
  trackedRecipients: number
  openedRecipients: number
  clickedRecipients: number
  uniqueClicks: number
  openRate: number
  clickRate: number
}

export interface ConsoleCampaignPreviewResponse {
  subject: string
  text: string | null
  html: string | null
}


export type ConsoleSuppressionScope =
  | 'global'
  | 'list'

export type ConsoleSuppressionReason =
  | 'manual'
  | 'hard_bounce'
  | 'unsubscribe'

export interface ConsoleSuppression {
  id: number
  email: string
  scope: ConsoleSuppressionScope
  reason: ConsoleSuppressionReason
  listId: number | null
  sourceMessageId: number | null
  createdAt: string
  updatedAt: string
}

export interface ConsoleSuppressionListResponse {
  items: ConsoleSuppression[]
}

export interface ConsoleProfileResponse {
  user: ConsoleUser
  stats: {
    messagesSent: number
    messagesSentScope: 'workspace'
    messagesReceived: number
    messagesReceivedAvailable: boolean
    favoriteContacts: number
  }
  favorites: ConsoleFavoriteContact[]
}
