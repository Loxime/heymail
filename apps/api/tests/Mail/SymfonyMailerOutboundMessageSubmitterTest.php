<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\BounceAddressCodec;
use App\Mail\EmailAddress;
use App\Mail\OutboundEmailPayload;
use App\Mail\SymfonyMailerOutboundMessageSubmitter;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Mailer\Envelope;
use Symfony\Component\Mailer\MailerInterface;
use Symfony\Component\Mime\Email;

final class SymfonyMailerOutboundMessageSubmitterTest
    extends TestCase
{
    public function testTransactionalMessageIsSubmittedWithManagedEnvelope(): void
    {
        $keyFile = tempnam(
            sys_get_temp_dir(),
            'heymail-bounce-',
        );

        self::assertIsString(
            $keyFile,
        );

        file_put_contents(
            $keyFile,
            str_repeat(
                'a',
                64,
            ),
        );

        try {
            $bounceAddressCodec =
                new BounceAddressCodec(
                    'heymail.test',
                    $keyFile,
                );

            $expectedSender =
                $bounceAddressCodec
                    ->senderFor(
                        42,
                    );

            self::assertMatchesRegularExpression(
                '/^bounce\+42\+'
                . '[a-f0-9]{32}'
                . '@heymail\.test$/D',
                $expectedSender,
            );

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

                            self::assertSame(
                                'sender@heymail.test',
                                $message
                                    ->getFrom()[0]
                                    ->getAddress(),
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
                        ) use (
                            $expectedSender,
                        ): bool {
                            self::assertInstanceOf(
                                Envelope::class,
                                $envelope,
                            );

                            self::assertSame(
                                $expectedSender,
                                $envelope
                                    ->getSender()
                                    ->getAddress(),
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
                    $bounceAddressCodec,
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
        } finally {
            @unlink(
                $keyFile,
            );
        }
    }
}
