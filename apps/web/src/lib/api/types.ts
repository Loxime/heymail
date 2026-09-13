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

export interface DashboardResponse {
  period: DashboardPeriod
  messages: DashboardMessages
  delivery: DashboardDelivery
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

