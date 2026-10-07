// Platform factory headers must remain usable without native SDK headers.
#include "../PNClip/Capture/CaptureBackendWin.hpp"
#include "../PNClip/Support/PlatformServicesWin.hpp"
#include "../PNClip/Core/AppController.hpp"
static_assert(pnclip::platformContractVersion == 1);
