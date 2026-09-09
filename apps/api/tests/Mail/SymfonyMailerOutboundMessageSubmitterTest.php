<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\EmailAddress;
use App\Mail\OutboundEmailPayload;
use App\Mail\SymfonyMailerOutboundMessageSubmitter;
use Symfony\Component\Mailer\Envelope;
use Symfony\Component\Mailer\MailerInterface;
use Symfony\Component\Mime\Email;
use PHPUnit\Framework\TestCase;

final class SymfonyMailerOutboundMessageSubmitterTest
    extends TestCase
{
    public function testTransactionalMessageIsSubmittedWithManagedEnvelope(): void
    {
        $mailer = $this->createMock(
            MailerInterface::class,
        );

        $mailer
            ->expects(self::once())
            ->method('send')
            ->with(
                self::callback(
                    static function (
                        mixed $message,
                    ): bool {
                        self::assertInstanceOf(
                            Email::class,
                            $message,
                        );

                        self::assertSame(
                            'Transactional subject',
                            $message->getSubject(),
                        );

                        self::assertSame(
                            'Plain body',
                            $message->getTextBody(),
                        );

                        self::assertSame(
                            '<p>HTML body</p>',
                            $message->getHtmlBody(),
                        );

                        self::assertCount(
                            1,
                            $message->getFrom(),
                        );

                        self::assertSame(
                            'sender@heymail.test',
                            $message
                                ->getFrom()[0]
                                ->getAddress(),
                        );

                        self::assertCount(
                            1,
                            $message->getTo(),
                        );

                        self::assertSame(
                            'recipient@success.test',
                            $message
                                ->getTo()[0]
                                ->getAddress(),
                        );

                        return true;
                    },
                ),
                self::callback(
                    static function (
                        mixed $envelope,
                    ): bool {
                        self::assertInstanceOf(
                            Envelope::class,
                            $envelope,
                        );

                        self::assertSame(
                            'bounce+42@heymail.test',
                            $envelope
                                ->getSender()
                                ->getAddress(),
                        );

                        self::assertCount(
                            1,
                            $envelope->getRecipients(),
                        );

                        self::assertSame(
                            'recipient@success.test',
                            $envelope
                                ->getRecipients()[0]
                                ->getAddress(),
                        );

                        return true;
                    },
                ),
            );

        $submitter =
            new SymfonyMailerOutboundMessageSubmitter(
                $mailer,
                'heymail.test',
            );

        $submitter->submit(
            42,
            new OutboundEmailPayload(
                from: new EmailAddress(
                    'sender@heymail.test',
                    'HeyMail',
                ),
                to: [
                    new EmailAddress(
                        'recipient@success.test',
                    ),
                ],
                subject: 'Transactional subject',
                textPart: 'Plain body',
                htmlPart: '<p>HTML body</p>',
            ),
        );
    }
}
