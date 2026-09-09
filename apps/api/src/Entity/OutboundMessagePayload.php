<?php

declare(strict_types=1);

namespace App\Entity;

use App\Mail\EncryptedOutboundEmailPayload;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity]
#[ORM\Table(name: 'outbound_message_payload')]
final class OutboundMessagePayload
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: Types::BIGINT)]
    // @phpstan-ignore property.unusedType
    private ?int $id = null;

    #[ORM\OneToOne(targetEntity: OutboundMessage::class)]
    #[ORM\JoinColumn(
        name: 'outbound_message_id',
        referencedColumnName: 'id',
        nullable: false,
        unique: true,
        onDelete: 'CASCADE',
    )]
    private OutboundMessage $outboundMessage;

    #[ORM\Column(type: Types::TEXT)]
    private string $ciphertext;

    #[ORM\Column(
        type: Types::STRING,
        length: 64,
    )]
    private string $nonce;

    #[ORM\Column(
        name: 'wrapped_dek',
        type: Types::STRING,
        length: 128,
    )]
    private string $wrappedDek;

    #[ORM\Column(
        name: 'wrap_nonce',
        type: Types::STRING,
        length: 64,
    )]
    private string $wrapNonce;

    #[ORM\Column(
        type: Types::STRING,
        length: 64,
    )]
    private string $algorithm;

    #[ORM\Column(
        name: 'key_version',
        type: Types::SMALLINT,
    )]
    private int $keyVersion;

    public function __construct(
        OutboundMessage $outboundMessage,
        EncryptedOutboundEmailPayload $encrypted,
    ) {
        $this->outboundMessage = $outboundMessage;
        $this->ciphertext = $encrypted->ciphertext;
        $this->nonce = $encrypted->nonce;
        $this->wrappedDek = $encrypted->wrappedDek;
        $this->wrapNonce = $encrypted->wrapNonce;
        $this->algorithm = $encrypted->algorithm;
        $this->keyVersion = $encrypted->keyVersion;
    }

    public function getId(): ?int
    {
        return $this->id;
    }

    public function getOutboundMessage(): OutboundMessage
    {
        return $this->outboundMessage;
    }

    public function encryptedPayload(): EncryptedOutboundEmailPayload
    {
        return new EncryptedOutboundEmailPayload(
            ciphertext: $this->ciphertext,
            nonce: $this->nonce,
            wrappedDek: $this->wrappedDek,
            wrapNonce: $this->wrapNonce,
            algorithm: $this->algorithm,
            keyVersion: $this->keyVersion,
        );
    }
}
