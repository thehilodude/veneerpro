# Veneer Pro: App Store Connect listing

Copy these into App Store Connect. Character limits are in brackets.

## App information
- **Name** [30]: Veneer Pro
  _If it's taken, try "Veneer Pro: CMF & AR" or "Veneer Pro CMF"._
- **Subtitle** [30]: CMF studio for AR models
- **Bundle ID**: com.thehilodude.veneerpro
- **SKU**: veneerpro-mac
- **Primary category**: Graphics & Design
- **Secondary category**: Productivity
- **Content rights**: does not contain third-party content
  _Downloaded materials come from CC0 libraries at the user's request._
- **Age rating**: answer "None" to every question (rated 4+).
- **Price**: Free (Pricing and Availability → USD 0).

## Version 1.2 text
**Promotional text** [170]:
> Preview colors, materials and finishes on real 3D models, compare colorways side by side, and send them to iPhone, iPad or Vision Pro in AR. No upload, no account.

**Description** [4000]:
> Veneer Pro is a color, material and finish (CMF) studio for 3D product models. Import a model, dress it in real materials, and see it in augmented reality on your iPhone, iPad or Apple Vision Pro in seconds.
>
> MATERIALS
> • Thousands of free PBR materials and HDRIs from ambientCG and Poly Haven, right in the app
> • Drag materials onto parts, or build your own with a node editor
> • Separate parts into their own materials, adjust texture mapping, and undo anything
>
> COLOR & FINISH
> • Pick colors from RAL Classic, RAL Design System+ and RAL Effect, or by hex, RGB or L*a*b*
> • Finish presets for paints, powder coats, anodizing, and SPI and VDI mold textures
> • See the nearest RAL match and ΔE for any color
> • Optional spray paint matches for students, with finish advice
>
> COLORWAYS & POSES
> • Save looks as colorways and switch or compare them side by side
> • Add hinges and pivots, then save poses such as open and closed
> • Colorways and poses export as USDZ variants: choose them right in AR Quick Look
>
> SEE IT FOR REAL
> • Share to iPhone or iPad over your own Wi-Fi with a QR code: no app or upload needed
> • AR Match shows how the model will look in AR before you send it
> • True Scale scenes and dimensions in cm and inches
>
> SPEC SHEETS & PROJECTS
> • Export a PDF spec sheet with renders, dimensions and every material's color and finish
> • Save everything in a single .vnr project file
>
> Imports USDZ, USD, OBJ, DAE, Alembic, PLY, STL and SceneKit files. Exports USDZ.

**Keywords** [100]:
> CMF,AR,USDZ,3D,materials,RAL,color,finish,product design,colorway,render,Vision Pro,industrial

**What's New**: (not needed for the first version)

**Support URL**: https://github.com/thehilodude/veneerpro/issues
**Marketing URL** (optional): https://github.com/thehilodude/veneerpro
**Privacy Policy URL**: https://github.com/thehilodude/veneerpro/blob/main/PRIVACY.md
  _This only works once PRIVACY.md has been pushed._

**Copyright**: 2026 Kevin Park

## Screenshots
Use `Design/AppStore/Screenshots/1.png`–`7.png` (1280 × 800, an accepted Mac size). At least 1 is required and at most 10 are allowed.

## App Privacy
- Data collection: **"No, we do not collect data from this app."**

## App Review information
- **Sign-in required**: No
- **Contact**: your name, phone and email
- **Attachment** (optional): a small USDZ model so the reviewer has something to open
- **Notes**:
> Veneer Pro edits 3D models. To try it, open any USDZ or OBJ file with File → Open (sample USDZ files are available at https://developer.apple.com/augmented-reality/quick-look/), or use the attached model. Materials and HDRIs can then be browsed in the Library tab (downloaded from ambientCG and Poly Haven, both CC0).
>
> The app uses the com.apple.security.network.server entitlement for "Share to iPhone or iPad": it runs a temporary local web server so the user's own iPhone or iPad on the same Wi-Fi can open the model in AR Quick Look via a QR code. The server only runs while the user is sharing and serves only the model they chose.
>
> No account is needed and no data is collected.

## Export compliance
Answered automatically: Info.plist sets ITSAppUsesNonExemptEncryption = NO. The app uses only Apple's built-in HTTPS for downloads.
