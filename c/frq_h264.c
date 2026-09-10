/* A flat C face for openh264's encoder.
 *
 * WHY THIS EXISTS. openh264's C API is not flat. `ISVCEncoder` is
 * `const ISVCEncoderVtbl*` — a pointer to a table of function pointers — so
 * calling Initialize or EncodeFrame means dereferencing the object, reading a
 * slot, and calling through it. jolt.ffi cannot do that: Chez fixes a foreign
 * procedure's types when it COMPILES it, and the target has to be a literal C
 * symbol name rather than a function pointer (see jolt/ffi.clj, "the target
 * must be a literal C symbol name"). So the vtable is walked here, in C, and
 * what jolt binds is the five plain symbols below.
 *
 * It is deliberately thin. No policy, no buffering beyond what openh264's own
 * output demands, and no decisions that belong in frq — the shim exists to
 * change a calling convention, not to be a video pipeline.
 *
 * THE ONE THING IT DOES DO is flatten the output. openh264 hands back an
 * SFrameBSInfo describing up to MAX_LAYER_NUM_OF_FRAME layers, each with its
 * own NAL count and a shared bitstream buffer. A caller wanting one Annex B
 * frame has to walk that; doing it in jolt would mean reading nested C structs
 * whose layout is openh264's business. It is copied into one contiguous
 * buffer owned by the encoder handle and handed over as a borrowed span,
 * valid until the next encode — which is exactly the contract frq.av already
 * has for a video frame.
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <wels/codec_api.h>
#include <wels/codec_app_def.h>

typedef struct {
  ISVCEncoder *enc;
  unsigned char *out;   /* flattened Annex B, grown as needed */
  size_t out_cap;
  int width, height;
} frq_h264;

/* Answers 0 on success, or openh264's own non-zero return. */
int frq_h264_open(int width, int height, int fps, int bitrate, void **handle) {
  ISVCEncoder *enc = NULL;
  frq_h264 *h;
  SEncParamBase p;
  int rc;

  *handle = NULL;
  rc = WelsCreateSVCEncoder(&enc);
  if (rc != 0 || enc == NULL) return rc ? rc : -1;

  memset(&p, 0, sizeof(p));
  p.iUsageType     = CAMERA_VIDEO_REAL_TIME;
  p.iPicWidth      = width;
  p.iPicHeight     = height;
  p.iTargetBitrate = bitrate;
  p.fMaxFrameRate  = (float)fps;

  rc = (*enc)->Initialize(enc, &p);
  if (rc != 0) { WelsDestroySVCEncoder(enc); return rc; }

  h = (frq_h264 *)calloc(1, sizeof(frq_h264));
  if (h == NULL) { (*enc)->Uninitialize(enc); WelsDestroySVCEncoder(enc); return -1; }
  h->enc = enc; h->width = width; h->height = height;
  *handle = h;
  return 0;
}

/* Encode one I420 frame.
 *
 * `i420` is width*height luma followed by two (width/2)*(height/2) planes.
 * On success answers 0 and sets *out / *out_len to a BORROWED span, valid
 * until the next call on this handle. *keyframe says whether it is an IDR.
 * A frame openh264 chose to skip answers 0 with *out_len == 0. */
int frq_h264_encode(void *handle, const unsigned char *i420, long long pts_us,
                    const unsigned char **out, int *out_len, int *keyframe) {
  frq_h264 *h = (frq_h264 *)handle;
  SSourcePicture pic;
  SFrameBSInfo info;
  int rc, i, j, total = 0, off = 0;

  *out = NULL; *out_len = 0; *keyframe = 0;

  memset(&pic, 0, sizeof(pic));
  pic.iPicWidth    = h->width;
  pic.iPicHeight   = h->height;
  pic.iColorFormat = videoFormatI420;
  pic.iStride[0]   = h->width;
  pic.iStride[1]   = h->width / 2;
  pic.iStride[2]   = h->width / 2;
  pic.pData[0]     = (unsigned char *)i420;
  pic.pData[1]     = pic.pData[0] + h->width * h->height;
  pic.pData[2]     = pic.pData[1] + (h->width / 2) * (h->height / 2);
  pic.uiTimeStamp  = pts_us / 1000;   /* openh264 counts milliseconds */

  memset(&info, 0, sizeof(info));
  rc = (*h->enc)->EncodeFrame(h->enc, &pic, &info);
  if (rc != cmResultSuccess) return rc;
  if (info.eFrameType == videoFrameTypeSkip) return 0;

  for (i = 0; i < info.iLayerNum; i++)
    for (j = 0; j < info.sLayerInfo[i].iNalCount; j++)
      total += info.sLayerInfo[i].pNalLengthInByte[j];

  if ((size_t)total > h->out_cap) {
    unsigned char *grown = (unsigned char *)realloc(h->out, (size_t)total);
    if (grown == NULL) return -1;
    h->out = grown; h->out_cap = (size_t)total;
  }
  for (i = 0; i < info.iLayerNum; i++) {
    int n = 0, k;
    for (k = 0; k < info.sLayerInfo[i].iNalCount; k++)
      n += info.sLayerInfo[i].pNalLengthInByte[k];
    memcpy(h->out + off, info.sLayerInfo[i].pBsBuf, (size_t)n);
    off += n;
  }

  *out = h->out;
  *out_len = total;
  *keyframe = (info.eFrameType == videoFrameTypeIDR);
  return 0;
}

int frq_h264_force_keyframe(void *handle) {
  frq_h264 *h = (frq_h264 *)handle;
  return (*h->enc)->ForceIntraFrame(h->enc, true);
}

void frq_h264_close(void *handle) {
  frq_h264 *h = (frq_h264 *)handle;
  if (h == NULL) return;
  if (h->enc) { (*h->enc)->Uninitialize(h->enc); WelsDestroySVCEncoder(h->enc); }
  free(h->out);
  free(h);
}
