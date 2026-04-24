-- migrate:up

-- New enums (scoped for sharing v2)
CREATE TYPE public.share_access_policy AS ENUM ('link_open', 'recipient_must_auth', 'revoked');
CREATE TYPE public.share_channel_type AS ENUM ('email', 'sms', 'apns', 'link');
CREATE TYPE public.share_provider AS ENUM ('resend', 'twilio', 'apns', 'system');
CREATE TYPE public.share_overall_status AS ENUM ('pending', 'scheduled', 'sent_some', 'sent_all', 'failed_all');
CREATE TYPE public.share_channel_status AS ENUM ('pending', 'scheduled', 'sending', 'sent', 'failed');
CREATE TYPE public.share_delivery_event AS ENUM ('queued', 'sent', 'failed');

COMMENT ON TYPE public.share_access_policy IS 'Access model for a share link.';
COMMENT ON TYPE public.share_overall_status IS 'Cached rollup across channels for a PhotobookShare.';
COMMENT ON TYPE public.share_channel_type IS 'Notification channel type.';
COMMENT ON TYPE public.share_channel_status IS 'Per-channel delivery status (source of truth is provider webhooks).';
COMMENT ON TYPE public.share_provider IS 'External provider for notifications.';
COMMENT ON TYPE public.share_delivery_event IS 'Immutable timeline event from send/webhooks.';

-- New sharing table (v2) – recipient fields inlined
CREATE TABLE public.shares (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  photobook_id uuid NOT NULL REFERENCES public.photobooks(id) ON DELETE CASCADE,
  created_by_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,

  -- Recipient is inlined here. For public links, both may be NULL.
  recipient_display_name text,                         -- e.g., "Mary", "Steven B"
  recipient_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL, -- registered user (optional)

  -- Link identity & control
  share_slug text NOT NULL UNIQUE,                     -- short, unguessable slug (e.g. sgf-7q3kntw)
  access_policy public.share_access_policy NOT NULL DEFAULT 'link_open',
  notes text,                                          -- optional owner/admin notes

  -- Status (cached/derived)
  overall_status public.share_overall_status NOT NULL DEFAULT 'pending',

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.shares
ADD CONSTRAINT chk_shares_auth_requires_identity
CHECK (
  access_policy <> 'recipient_must_auth'
  OR recipient_user_id IS NOT NULL
);

COMMENT ON TABLE public.shares IS 'Per-recipient (or public) share for a photobook. Recipient fields are inlined.';

-- Helpful indexes
CREATE INDEX idx_shares_photobook_id ON public.shares (photobook_id);
CREATE INDEX idx_shares_access_policy ON public.shares (access_policy);
CREATE INDEX idx_shares_overall_status ON public.shares (overall_status);

-- Unique constraint: at most one identical channel set per destination is enforced at the channel level.
-- We intentionally allow multiple shares per photobook to support regenerations / variants.

-- Per-avenue channel rows
CREATE TABLE public.share_channels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  photobook_share_id uuid NOT NULL REFERENCES public.shares(id) ON DELETE CASCADE,

  channel_type public.share_channel_type NOT NULL,     -- email | sms | apns | link
  destination text NOT NULL,                           -- normalized address: lowercased email, E.164 phone, APNs token
  status public.share_channel_status NOT NULL DEFAULT 'pending',
  last_error text,
  last_provider_message_id text,
  scheduled_for timestamptz,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT uq_share_channels_unique_destination
    UNIQUE (photobook_share_id, channel_type, destination)
);

COMMENT ON TABLE public.share_channels IS 'One row per delivery avenue (email/sms/apns) under a share.';

CREATE INDEX idx_share_channels_share_id ON public.share_channels (photobook_share_id);
CREATE INDEX idx_share_channels_status ON public.share_channels (status);
CREATE INDEX idx_share_channels_scheduled_for ON public.share_channels (scheduled_for);

-- Immutable delivery/log timeline (append-only)
CREATE TABLE public.share_delivery_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  share_channel_id uuid NOT NULL REFERENCES public.share_channels(id) ON DELETE CASCADE,
  provider public.share_provider NOT NULL,
  event public.share_delivery_event NOT NULL,
  payload jsonb,                                       -- raw provider payload (sanitized as needed)
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.share_delivery_attempts IS 'Append-only audit of send/webhook events for a share channel.';

CREATE INDEX idx_share_delivery_attempts_channel_created
  ON public.share_delivery_attempts (share_channel_id, created_at);






-- migrate:down

-- Drop in reverse dependency order
DROP INDEX IF EXISTS idx_share_delivery_attempts_channel_created;
DROP TABLE IF EXISTS public.share_delivery_attempts;

DROP INDEX IF EXISTS idx_share_channels_scheduled_for;
DROP INDEX IF EXISTS idx_share_channels_status;
DROP INDEX IF EXISTS idx_share_channels_share_id;
DROP TABLE IF EXISTS public.share_channels;

DROP INDEX IF EXISTS idx_shares_overall_status;
DROP INDEX IF EXISTS idx_shares_access_policy;
DROP INDEX IF EXISTS idx_shares_photobook_id;
-- share_slug has an implicit unique index created by UNIQUE constraint
DROP TABLE IF EXISTS public.shares;

-- Types last
DROP TYPE IF EXISTS public.share_delivery_event;
DROP TYPE IF EXISTS public.share_provider;
DROP TYPE IF EXISTS public.share_channel_status;
DROP TYPE IF EXISTS public.share_channel_type;
DROP TYPE IF EXISTS public.share_overall_status;
DROP TYPE IF EXISTS public.share_access_policy;
