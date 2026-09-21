<?php

declare(strict_types=1);

namespace App\Mail;

use InvalidArgumentException;
use Symfony\Component\Mailer\Envelope;
use Symfony\Component\Mailer\MailerInterface;
use Symfony\Component\Mime\Address;
use Symfony\Component\Mime\Email;

final class SymfonyMailerOutboundMessageSubmitter implements
    OutboundMessageSubmitter
{
    public function __construct(
        private readonly MailerInterface $mailer,
        private readonly BounceAddressCodec $bounceAddressCodec,
    ) {
    }

    public function submit(
        int $outboundMessageId,
        OutboundEmailPayload $payload,
    ): void {
        if ($outboundMessageId < 1) {
            throw new InvalidArgumentException(
                'Outbound message identifier must be positive.',
            );
        }

        $from = self::toMimeAddress(
            $payload->from,
        );

        $recipients = array_map(
            static fn (
                EmailAddress $address,
            ): Address => self::toMimeAddress(
                $address,
            ),
            $payload->to,
        );

        $email = new Email();

        $email
            ->from($from)
            ->to(...$recipients)
            ->subject($payload->subject);

        if ($payload->replyTo !== null) {
            $email->replyTo(
                self::toMimeAddress(
                    $payload->replyTo,
                ),
            );
        }

        if ($payload->textPart !== null) {
            $email->text(
                $payload->textPart,
            );
        }

        if ($payload->htmlPart !== null) {
            $email->html(
                $payload->htmlPart,
            );
        }

        if ($payload->unsubscribeUrl !== null) {
            $email
                ->getHeaders()
                ->addTextHeader(
                    'List-Unsubscribe',
                    sprintf(
                        '<%s>',
                        $payload->unsubscribeUrl,
                    ),
                );

            $email
                ->getHeaders()
                ->addTextHeader(
                    'List-Unsubscribe-Post',
                    'List-Unsubscribe=One-Click',
                );
        }

        $email
            ->getHeaders()
            ->addIdHeader(
                'Message-ID',
                sprintf(
                    'heymail-%d@%s',
                    $outboundMessageId,
                    $this
                        ->bounceAddressCodec
                        ->domain(),
                ),
            );

        $envelope = new Envelope(
            new Address(
                $this
                    ->bounceAddressCodec
                    ->senderFor(
                        $outboundMessageId,
                    ),
            ),
            $recipients,
        );

        $this->mailer->send(
            $email,
            $envelope,
        );
    }

    private static function toMimeAddress(
        EmailAddress $address,
    ): Address {
        return new Address(
            $address->email,
            $address->name ?? '',
        );
    }
}
