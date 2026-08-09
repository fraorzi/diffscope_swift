export function send(recipientEmail: string) {
  return transport.send({ to: recipientEmail });
}
