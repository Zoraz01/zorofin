// Android and TV privacy text. Keep changes aligned with the implemented
// phone, tablet and TV capabilities;
// Apple maintains its separate public policy in apps/apple/release/.

/// Privacy Policy, App Support and Sample Media Credits (Apple
/// `PublicDocument`).
enum PublicDocument {
  privacy(
    "Privacy Policy",
    "Zorofin is a Jellyfin client published by Vitality Labs LLC. You choose the server you connect to. Zorofin does not provide a media subscription, a public server directory, or an account signup service.",
    [
      (
        "Your device and saved sign-ins",
        [
          "On Android phones and tablets, Android TV, Google TV and Fire OS, saved sign-ins are encrypted on the device with keys protected by Android Keystore. Existing saved sign-ins are migrated out of ordinary preferences after the encrypted copy is verified. The LG webOS and Linux preview ports currently use app-private preferences and do not claim Keystore protection. Zorofin saves account and server details, app preferences and account-scoped caches on your device. Your password is used to authenticate with the server you enter; Zorofin does not keep that password as a saved sign-in credential.",
          "Removing a saved account removes its saved credentials from this app. Storage & app settings let you clear cached artwork and library responses. Removing local data does not delete the account, watch history or other records held by your server.",
          "On phones and tablets, titles you choose to download are saved in the app's private storage on this device, with their artwork and the account they belong to. They stay until you remove them or remove that account. Watching a download offline saves your progress on the device and sends it to your server once it can be reached.",
        ],
      ),
      (
        "Connecting, browsing and watching",
        [
          "The server you select receives connection and account information needed to sign in, plus requests for library items, searches, artwork and playback. Jellyfin session reporting sends playback progress, pause/stop state, the app/client version and a generated client device identifier. Favorites, watched status, playlists and other changes are sent when you use those features.",
          "Your server and its hosting/network providers can see your network address and may retain access logs and account activity. Its operator controls that processing and retention. Use a server you trust and contact its operator about server-side records. HTTPS is preferred; allowing local HTTP sends traffic without transport encryption on that local connection.",
        ],
      ),
      (
        "Fire TV home-screen recommendations",
        [
          "Recommendations are off by default for each saved account. If you enable them, the app shares selected library titles, episode labels and thumbnail images with the Fire TV launcher on that device. Anyone using the TV may see them. The app does not include a server address, password or sign-in token in those cards. Device features are also governed by your device provider's policies.",
          "Turning recommendations off, signing out or switching accounts clears the app's previous cards. A card opens only within its original signed-in account. This feature does not integrate Amazon's cloud watch-history personalization API.",
        ],
      ),
      (
        "Optional requests and notifications",
        [
          "Servers that advertise compatible request features can receive your account identifier, searches, requested titles and selected seasons, and retain request and availability records. Request artwork may load from The Movie Database image service; that service receives the image request and your network address. Zorofin does not send your Jellyfin token to that image service.",
          "If you enable a server's email or push alerts, the address or delivery settings you enter are sent to that server. Its operator and configured delivery providers handle those alerts. Notification history and read state may also be saved on your device and, where supported, on the server. Basic Jellyfin browsing and playback do not require these optional services.",
        ],
      ),
      (
        "Support reports and AI assistance",
        [
          "Sending a server support report shares the issue type, your description, any affected title you enter and your signed-in account context with that server's administrators and support service. That service may use an external AI provider to investigate or draft replies, and may consult relevant server or playback diagnostics. Review the notice in the report form before agreeing to send a report. Do not include passwords, payment details or other sensitive information.",
          "The server operator determines its support providers and retention practices. Ask the operator for provider-specific information before sending anything you do not want processed that way. You can use the app support email instead of server support. Emailing us sends the information you choose to include to Vitality Labs LLC and our email provider. App stores handle feedback submitted through their own services under their policies.",
        ],
      ),
      (
        "Profile photos, settings and administration",
        [
          "The app can display or remove the profile photo held by your server. It does not provide a photo-library picker. Account, subtitle, alert and playback preferences are sent to your server when those settings are server-managed.",
          "On TVs, administrator pages provide instructions for opening the selected server's web interface on another device. On phones and tablets, the Dashboard and Metadata Manager open the server's web interface in your browser, where you sign in to the server separately. The app does not embed an administrative browser or share its saved token with the browser or another device.",
        ],
      ),
      (
        "Advertising, tracking and diagnostics",
        [
          "Zorofin does not include advertising, cross-app tracking, a data-broker integration, or a third-party analytics SDK. We do not sell app data or use it for targeted advertising. We do not receive a central copy of every connected server's library or activity just because you installed the client.",
          "Your device manufacturer or app store may provide crash or beta diagnostics according to your device settings and choices. Zorofin does not automatically upload a separate diagnostic bundle to Vitality Labs LLC. Information you include in a support report or email is handled as described above.",
        ],
      ),
      (
        "Visiting our public website",
        [
          "Our public information pages are hosted on Cloudflare. Cloudflare processes basic connection and request information, such as your network address, to deliver the pages and protect the service. These pages do not include advertising, analytics scripts or a sign-in form. Contacting app support by email is a separate action you choose to take.",
        ],
      ),
      (
        "Retention, deletion and your choices",
        [
          "Local caches are bounded and may be cleared or replaced as you use the app. You can remove saved accounts, clear caches and change preferences in the app. Server operators control the retention and deletion of accounts, watch history, requests, photos and server support records; local sign-out does not erase those records.",
          "For support correspondence held by Vitality Labs LLC, contact us to request access, correction or deletion. We retain correspondence as needed to investigate and resolve issues, maintain necessary support records, and meet legal obligations. We do not promise to delete records controlled by an independent server operator, device manufacturer or app store.",
        ],
      ),
      (
        "Contact and changes",
        [
          "For questions about the Zorofin client or this policy, contact Vitality Labs LLC at zoraz@vitalitylabssolutions.com. For a server account or its content and records, contact that server's operator. This policy may change as app features or processing practices change; the updated date identifies this version.",
        ],
      ),
    ],
  ),
  support(
    "App Support",
    "Need help with the Zorofin client? Contact Vitality Labs LLC at zoraz@vitalitylabssolutions.com.",
    [
      (
        "Report an app problem",
        [
          "Include your app version, device model, operating system version, what you expected, what happened and the steps to reproduce it. A redacted screenshot can help. Do not send passwords, authentication tokens, private server addresses, payment details or unredacted account information. Beta testers can also use the feedback options provided by their app store.",
        ],
      ),
      (
        "Your server and account",
        [
          "Zorofin requires access to a Jellyfin server that you choose. We do not provide accounts, media subscriptions, a public server directory or access to movies and shows. Contact your server operator for an account, forgotten password, missing media or server availability. Optional Requests, Support and notification features depend on that server's capabilities and permissions.",
        ],
      ),
      (
        "Playback problems",
        [
          "Tell us whether the issue affects a particular title, Live TV or all playback, and whether it occurs on Wi-Fi, cellular or an external display. You can include codec and subtitle names shown in Playback info. Redact title and server details you do not want to share. Your server may need to convert formats that your device cannot play directly.",
        ],
      ),
      (
        "Privacy and sample content",
        [
          "Read the Privacy Policy from the connection screen or Profile without signing into a separate website. Sample films used in release screenshots are separately licensed demonstration content; the app does not include a movie library or a connection to a demonstration server. Sample film and image credits must accompany screenshots and other materials where required by their licenses.",
        ],
      ),
    ],
  ),
  credits(
    "Sample Media Credits",
    "These open films and derived images are used on a separate demonstration server and may appear in Zorofin release screenshots. They are not bundled media or a subscription included with the app. No endorsement of Zorofin is implied.",
    [
      (
        "Big Buck Bunny (2008)",
        [
          "© Blender Foundation | www.bigbuckbunny.org. Creative Commons Attribution 3.0: https://creativecommons.org/licenses/by/3.0/. Source: https://download.blender.org/demo/movies/BBB/. The full film and its credits are retained. Audio was converted to AAC and the MP4 index moved for Apple playback; artwork uses cropped/scaled film frames.",
        ],
      ),
      (
        "Sintel (2010)",
        [
          "© Blender Foundation | durian.blender.org. Creative Commons Attribution 3.0: https://creativecommons.org/licenses/by/3.0/. License information: https://durian.blender.org/sharing/. The full film and its credits are retained. Video is unchanged; audio was converted to AAC stereo and artwork uses cropped/scaled film frames.",
        ],
      ),
      (
        "Tears of Steel (2012)",
        [
          "© Blender Foundation | mango.blender.org. Creative Commons Attribution 3.0: https://creativecommons.org/licenses/by/3.0/. License information: https://mango.blender.org/about/. The full film and its credits are retained. Video is unchanged; audio was converted to AAC stereo and artwork uses cropped/scaled film frames. No separately licensed soundtrack album is redistributed.",
        ],
      ),
      (
        "Elephants Dream (2006)",
        [
          "© 2006 Blender Foundation / Netherlands Media Art Institute | www.elephantsdream.org. Creative Commons Attribution 2.5: https://creativecommons.org/licenses/by/2.5/. Source and permission: https://orange.blender.org/press/. The full film, original credits and mixed soundtrack are retained; artwork uses cropped/scaled film frames. No separately licensed soundtrack album is redistributed.",
        ],
      ),
      (
        "Caminandes 2: Gran Dillama (2013)",
        [
          "© Blender Foundation | www.caminandes.com. Creative Commons Attribution 3.0: https://creativecommons.org/licenses/by/3.0/. The complete official film, including its closing CC BY 3.0 card and credits, is retained. Source: https://video.blender.org/videos/watch/fb70d459-48d2-4db5-adba-813c84f9200a. Artwork uses cropped/scaled film frames.",
        ],
      ),
      (
        "Caminandes 3: Llamigos (2016)",
        [
          "© Blender Foundation | cloud.blender.org/p/caminandes-3. The official Blender video publisher identifies this film as Creative Commons Attribution (CC BY); its video metadata does not specify a license version. Publisher license record: https://video.blender.org/api/v1/videos/23f3ef79-15dc-44c5-aa45-cf92e78a4509. Creative Commons license information: https://creativecommons.org/licenses/. The complete film and credits are retained; artwork uses cropped/scaled film frames.",
        ],
      ),
      (
        "Screenshot attribution",
        [
          "Keep the film name, Blender Foundation credit, source and license with any exported screenshot or promotional material containing these images. Identify crops or other adaptations. This permission does not establish rights to Zorofin branding or third-party trademark logos.",
        ],
      ),
    ],
  );

  const PublicDocument(this.title, this.intro, this.sections);

  static const contact = "zoraz@vitalitylabssolutions.com";
  static const updated = "November 7, 2026";

  final String title;
  final String intro;
  final List<(String, List<String>)> sections;
}
