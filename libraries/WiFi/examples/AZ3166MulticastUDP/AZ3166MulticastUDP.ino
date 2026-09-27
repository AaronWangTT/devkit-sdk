#include <AZ3166MulticastUdp.h>
#include <AZ3166WiFi.h>

char ssid[] = "yournetworkssid";
char pass[] = "yourpassword";

const IPAddress multicastGroup(239, 255, 0, 1);
const unsigned short multicastPort = 5000;
AZ3166MulticastUDP udp;

void setup()
{
  Serial.begin(115200);
  while (WiFi.begin(ssid, pass) != WL_CONNECTED) {
    Serial.println("Waiting for Wi-Fi...");
    delay(10000);
  }

  IPAddress localIP = WiFi.localIP();
  uint32_t localAddress = (static_cast<uint32_t>(localIP[0]) << 24) |
      (static_cast<uint32_t>(localIP[1]) << 16) |
      (static_cast<uint32_t>(localIP[2]) << 8) |
      static_cast<uint32_t>(localIP[3]);
  udp.setLocalIPv4Address(localAddress);
  if (!udp.beginMulticast(multicastGroup, multicastPort)) {
    Serial.println("Unable to join multicast group");
    while (true);
  }

  Serial.println("Listening for multicast UDP packets");
}

void loop()
{
  int packetSize = udp.parsePacket();
  if (packetSize <= 0) {
    delay(20);
    return;
  }

  unsigned char buffer[128];
  int bytesRead = udp.read(buffer, sizeof(buffer));
  IPAddress sender = udp.remoteIP();
  unsigned short senderPort = udp.remotePort();

  Serial.print("Received ");
  Serial.print(bytesRead);
  Serial.print(" bytes from ");
  Serial.print(sender);
  Serial.print(':');
  Serial.println(senderPort);

  const char reply[] = "AZ3166 multicast reply";
  if (!udp.beginPacket(multicastGroup, multicastPort) ||
      udp.write((const unsigned char *)reply, sizeof(reply) - 1) != sizeof(reply) - 1 ||
      !udp.endPacket()) {
    Serial.println("Unable to send multicast reply");
  }
}
