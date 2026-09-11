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
final class SendingDomain
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: Types::BIGINT)]
    // @phpstan-ignore property.unusedType
    private ?int $id = null;

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
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $verifiedAt = null;

    #[ORM\Column(
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $disabledAt = null;

    public function __construct(
        DomainName $domain,
        string $verificationToken,
        ?DateTimeImmutable $createdAt = null,
    ) {
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

        $this->createdAt = $createdAt
            ?? new DateTimeImmutable(
                'now',
                new DateTimeZone('UTC'),
            );
    }

    public function getId(): ?int
    {
        return $this->id;
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

    public function getVerifiedAt(): ?DateTimeImmutable
    {
        return $this->verifiedAt;
    }

    public function getDisabledAt(): ?DateTimeImmutable
    {
        return $this->disabledAt;
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

        $this->status =
            SendingDomainStatus::VERIFIED;

        $this->verifiedAt = $at
            ?? new DateTimeImmutable(
                'now',
                new DateTimeZone('UTC'),
            );
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

        $this->disabledAt = $at
            ?? new DateTimeImmutable(
                'now',
                new DateTimeZone('UTC'),
            );
    }
}
