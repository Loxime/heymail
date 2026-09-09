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
    private string $bounceDomain;

    public function __construct(
        private readonly MailerInterface $mailer,
        string $bounceDomain,
    ) {
        if (
            $bounceDomain === ''
            || str_contains(
                $bounceDomain,
                '@',
            )
            || filter_var(
                'probe@' . $bounceDomain,
                FILTER_VALIDATE_EMAIL,
            ) === false
        ) {
            throw new InvalidArgumentException(
                'Invalid HeyMail bounce domain.',
            );
        }

        $this->bounceDomain = $bounceDomain;
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

        $email
            ->getHeaders()
            ->addIdHeader(
                'Message-ID',
                sprintf(
                    'heymail-%d@%s',
                    $outboundMessageId,
                    $this->bounceDomain,
                ),
            );

        $envelope = new Envelope(
            new Address(
                sprintf(
                    'bounce+%d@%s',
                    $outboundMessageId,
                    $this->bounceDomain,
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
