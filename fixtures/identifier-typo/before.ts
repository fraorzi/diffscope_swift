export function send(recepientEmail: string) {
  return transport.send({ to: recepientEmail });
}
