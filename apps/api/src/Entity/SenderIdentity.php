<?php

declare(strict_types=1);

namespace App\Entity;

use App\Enum\SendingDomainStatus;
use App\Mail\SenderEmailAddress;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use LogicException;

#[ORM\Entity]
#[ORM\Table(name: 'sender_identity')]
#[ORM\UniqueConstraint(
    name: 'uniq_sender_identity_email',
    columns: ['email'],
)]
#[ORM\Index(
    name: 'idx_sender_identity_domain',
    columns: ['sending_domain_id'],
)]
final class SenderIdentity
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: Types::BIGINT)]
    // @phpstan-ignore property.unusedType
    private ?int $id = null;

    #[ORM\ManyToOne(
        targetEntity: SendingDomain::class,
    )]
    #[ORM\JoinColumn(
        name: 'sending_domain_id',
        referencedColumnName: 'id',
        nullable: false,
        onDelete: 'RESTRICT',
    )]
    private SendingDomain $sendingDomain;

    #[ORM\Column(
        type: Types::STRING,
        length: 254,
    )]
    private string $email;

    #[ORM\Column(
        type: Types::DATETIME_IMMUTABLE,
    )]
    private DateTimeImmutable $createdAt;

    public function __construct(
        SendingDomain $sendingDomain,
        SenderEmailAddress $email,
        ?DateTimeImmutable $createdAt = null,
    ) {
        if (
            $sendingDomain->getStatus()
            !== SendingDomainStatus::VERIFIED
            || !$sendingDomain->isDkimReady()
        ) {
            throw new LogicException(
                'Sender identity requires a verified DKIM-ready sending domain.',
            );
        }

        if (
            $email->domain
            !== $sendingDomain->getDomain()
        ) {
            throw new LogicException(
                'Sender identity email does not belong to the sending domain.',
            );
        }

        $this->sendingDomain =
            $sendingDomain;

        $this->email =
            $email->value;

        $this->createdAt =
            $createdAt
            ?? new DateTimeImmutable(
                'now',
                new DateTimeZone('UTC'),
            );
    }

    public function getId(): ?int
    {
        return $this->id;
    }

    public function getSendingDomain(): SendingDomain
    {
        return $this->sendingDomain;
    }

    public function getEmail(): string
    {
        return $this->email;
    }

    public function getCreatedAt(): DateTimeImmutable
    {
        return $this->createdAt;
    }

    public function isAuthorized(): bool
    {
        return $this
            ->sendingDomain
            ->getStatus()
            === SendingDomainStatus::VERIFIED
            && $this
                ->sendingDomain
                ->isDkimReady();
    }
}
