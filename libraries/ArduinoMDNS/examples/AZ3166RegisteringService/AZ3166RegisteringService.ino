#include <ArduinoMDNS.h>
#include <AZ3166MulticastUdp.h>
#include <AZ3166WiFi.h>

char ssid[] = "yournetworkssid";
char pass[] = "yourpassword";

AZ3166MulticastUDP udp;
MDNS mdns(udp, false);

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

  if (!mdns.begin(localIP, "az3166") ||
      !mdns.addServiceRecord(
          "az3166._http", 80, MDNSServiceTCP, "path=/")) {
    Serial.println("Unable to start mDNS");
    while (true);
  }

  Serial.println("mDNS service available at az3166.local");
}

void loop()
{
  mdns.run();
  if (udp.failed()) {
    Serial.println("mDNS transport failed");
    mdns.end();
    while (true);
  }
  delay(20);
}
