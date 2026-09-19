<?php

declare(strict_types=1);

namespace App\Entity;

use App\Enum\SendingDomainStatus;
use App\Mail\DomainName;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use InvalidArgumentException;
use LogicException;

#[ORM\Entity]
#[ORM\Table(name: 'sending_domain')]
#[ORM\UniqueConstraint(
    name: 'uniq_sending_domain_domain',
    columns: ['domain'],
)]
#[ORM\UniqueConstraint(
    name: 'uniq_sending_domain_verification_token',
    columns: ['verification_token'],
)]
#[ORM\Index(
    name: 'idx_sending_domain_workspace',
    columns: [
        'workspace_id',
        'id',
    ],
)]
final class SendingDomain
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: Types::BIGINT)]
    // @phpstan-ignore property.unusedType
    private ?int $id = null;

    #[ORM\Column(
        name: 'workspace_id',
        type: Types::BIGINT,
        nullable: true,
    )]
    private ?int $workspaceId = null;

    #[ORM\Column(
        type: Types::STRING,
        length: 253,
    )]
    private string $domain;

    #[ORM\Column(
        type: Types::STRING,
        length: 32,
        enumType: SendingDomainStatus::class,
    )]
    private SendingDomainStatus $status;

    #[ORM\Column(
        name: 'verification_token',
        type: Types::STRING,
        length: 64,
    )]
    private string $verificationToken;

    #[ORM\Column(type: Types::DATETIME_IMMUTABLE)]
    private DateTimeImmutable $createdAt;

    #[ORM\Column(
        name: 'verification_checked_at',
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $verificationCheckedAt = null;

    #[ORM\Column(
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $verifiedAt = null;

    #[ORM\Column(
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $disabledAt = null;

    #[ORM\Column(
        name: 'dkim_selector',
        type: Types::STRING,
        length: 63,
        nullable: true,
    )]
    private ?string $dkimSelector = null;

    #[ORM\Column(
        name: 'dkim_public_key',
        type: Types::TEXT,
        nullable: true,
    )]
    private ?string $dkimPublicKey = null;

    #[ORM\Column(
        name: 'dkim_provisioned_at',
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $dkimProvisionedAt = null;

    public function __construct(
        DomainName $domain,
        string $verificationToken,
        ?DateTimeImmutable $createdAt = null,
        ?int $workspaceId = null,
    ) {
        if (
            $workspaceId !== null
            && $workspaceId < 1
        ) {
            throw new InvalidArgumentException(
                'Invalid sending domain workspace.',
            );
        }

        $this->workspaceId = $workspaceId;

        if (
            preg_match(
                '/^[a-f0-9]{64}$/D',
                $verificationToken,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid sending domain verification token.',
            );
        }

        $this->domain =
            $domain->value;

        $this->verificationToken =
            $verificationToken;

        $this->status =
            SendingDomainStatus::PENDING;

        $this->createdAt =
            $createdAt
            ?? self::now();
    }

    public function getId(): ?int
    {
        return $this->id;
    }

    public function getWorkspaceId(): ?int
    {
        return $this->workspaceId;
    }

    public function getDomain(): string
    {
        return $this->domain;
    }

    public function getStatus(): SendingDomainStatus
    {
        return $this->status;
    }

    public function getVerificationToken(): string
    {
        return $this->verificationToken;
    }

    public function getCreatedAt(): DateTimeImmutable
    {
        return $this->createdAt;
    }

    public function getVerificationCheckedAt(): ?DateTimeImmutable
    {
        return $this->verificationCheckedAt;
    }

    public function getVerifiedAt(): ?DateTimeImmutable
    {
        return $this->verifiedAt;
    }

    public function getDisabledAt(): ?DateTimeImmutable
    {
        return $this->disabledAt;
    }

    public function getDkimSelector(): ?string
    {
        return $this->dkimSelector;
    }

    public function getDkimPublicKey(): ?string
    {
        return $this->dkimPublicKey;
    }

    public function getDkimProvisionedAt(): ?DateTimeImmutable
    {
        return $this->dkimProvisionedAt;
    }

    public function isDkimReady(): bool
    {
        return $this->dkimSelector !== null
            && $this->dkimPublicKey !== null
            && $this->dkimProvisionedAt !== null;
    }

    public function getDkimRecordName(): ?string
    {
        if (
            !$this->isDkimReady()
        ) {
            return null;
        }

        return sprintf(
            '%s._domainkey.%s',
            $this->dkimSelector,
            $this->domain,
        );
    }

    public function getDkimRecordValue(): ?string
    {
        if (
            !$this->isDkimReady()
        ) {
            return null;
        }

        return sprintf(
            'v=DKIM1; k=rsa; p=%s',
            $this->dkimPublicKey,
        );
    }

    public function getVerificationRecordName(): string
    {
        return sprintf(
            '_heymail-verification.%s',
            $this->domain,
        );
    }

    public function getVerificationRecordValue(): string
    {
        return sprintf(
            'heymail-verification=%s',
            $this->verificationToken,
        );
    }

    public function markVerificationChecked(
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            === SendingDomainStatus::DISABLED
        ) {
            throw new LogicException(
                'Disabled sending domain cannot be verified.',
            );
        }

        if (
            $this->status
            === SendingDomainStatus::VERIFIED
        ) {
            return;
        }

        $this->verificationCheckedAt =
            $at
            ?? self::now();
    }

    public function markVerified(
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            === SendingDomainStatus::VERIFIED
        ) {
            return;
        }

        if (
            $this->status
            !== SendingDomainStatus::PENDING
        ) {
            throw new LogicException(
                'Disabled sending domain cannot be verified.',
            );
        }

        $verifiedAt =
            $at
            ?? self::now();

        $this->status =
            SendingDomainStatus::VERIFIED;

        $this->verificationCheckedAt =
            $verifiedAt;

        $this->verifiedAt =
            $verifiedAt;
    }

    public function markDkimProvisioned(
        string $selector,
        string $publicKey,
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            !== SendingDomainStatus::VERIFIED
        ) {
            throw new LogicException(
                'DKIM can only be provisioned for a verified sending domain.',
            );
        }

        if (
            preg_match(
                '/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/D',
                $selector,
            ) !== 1
            || $publicKey === ''
            || base64_decode(
                $publicKey,
                true,
            ) === false
        ) {
            throw new InvalidArgumentException(
                'Invalid DKIM key material.',
            );
        }

        if ($this->isDkimReady()) {
            if (
                $this->dkimSelector !== $selector
                || !hash_equals(
                    (string) $this->dkimPublicKey,
                    $publicKey,
                )
            ) {
                throw new LogicException(
                    'Provisioned DKIM material cannot be replaced implicitly.',
                );
            }

            return;
        }

        $this->dkimSelector =
            $selector;

        $this->dkimPublicKey =
            $publicKey;

        $this->dkimProvisionedAt =
            $at
            ?? self::now();
    }

    public function disable(
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            === SendingDomainStatus::DISABLED
        ) {
            return;
        }

        $this->status =
            SendingDomainStatus::DISABLED;

        $this->disabledAt =
            $at
            ?? self::now();
    }

    private static function now(): DateTimeImmutable
    {
        return new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );
    }
}
