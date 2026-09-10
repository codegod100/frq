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

/* --- decoding -------------------------------------------------------------
 *
 * Same vtable problem, same answer. ISVCDecoder is `const ISVCDecoderVtbl*`,
 * so DecodeFrameNoDelay is a function pointer and jolt cannot reach it.
 *
 * What comes out is I420 in the decoder's OWN buffers, three planes with
 * their own strides — which are not the width. A decoder pads its rows, so
 * copying `width` bytes per row from a `stride`-wide plane is the mistake
 * that produces a picture sheared diagonally, and it is why the strides are
 * carried through to the converter below rather than assumed away.
 */
#include <wels/codec_def.h>

typedef struct {
  ISVCDecoder *dec;
  unsigned char *rgba;      /* converted output, grown as needed */
  size_t rgba_cap;
} frq_h264_dec;

int frq_h264_decoder_open(void **handle) {
  ISVCDecoder *dec = NULL;
  frq_h264_dec *d;
  SDecodingParam p;
  int rc;

  *handle = NULL;
  rc = WelsCreateDecoder(&dec);
  if (rc != 0 || dec == NULL) return rc ? rc : -1;

  memset(&p, 0, sizeof(p));
  p.eEcActiveIdc = ERROR_CON_SLICE_COPY;
  p.sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;

  rc = (int)(*dec)->Initialize(dec, &p);
  if (rc != 0) { WelsDestroyDecoder(dec); return rc; }

  d = (frq_h264_dec *)calloc(1, sizeof(frq_h264_dec));
  if (d == NULL) { (*dec)->Uninitialize(dec); WelsDestroyDecoder(dec); return -1; }
  d->dec = dec;
  *handle = d;
  return 0;
}

/* Decode one Annex B frame and convert it to RGBA.
 *
 * RGBA rather than I420 because that is what the far end of this is:
 * vidya/frame-rgba! takes a tightly packed RGBA buffer, and converting here
 * means the pixels are touched once, in C, instead of crossing into jolt to
 * be rearranged. On success answers 0; *out is NULL and *w/*h are 0 when the
 * decoder has no picture yet, which is normal for the first packets. */
int frq_h264_decode_rgba(void *handle, const unsigned char *annexb, int len,
                         const unsigned char **out, int *w, int *h) {
  frq_h264_dec *d = (frq_h264_dec *)handle;
  unsigned char *planes[3] = {NULL, NULL, NULL};
  SBufferInfo info;
  DECODING_STATE st;
  int width, height, y, x, sy, su, sv;
  size_t need;

  *out = NULL; *w = 0; *h = 0;
  memset(&info, 0, sizeof(info));

  st = (*d->dec)->DecodeFrameNoDelay(d->dec, annexb, len, planes, &info);
  if (st != dsErrorFree) return (int)st;
  if (info.iBufferStatus != 1) return 0;     /* no picture this time */

  width  = info.UsrData.sSystemBuffer.iWidth;
  height = info.UsrData.sSystemBuffer.iHeight;
  sy = info.UsrData.sSystemBuffer.iStride[0];
  su = info.UsrData.sSystemBuffer.iStride[1];
  sv = su;
  if (width <= 0 || height <= 0) return 0;

  need = (size_t)width * (size_t)height * 4u;
  if (need > d->rgba_cap) {
    unsigned char *grown = (unsigned char *)realloc(d->rgba, need);
    if (grown == NULL) return -1;
    d->rgba = grown; d->rgba_cap = need;
  }

  /* BT.601 limited range, integer. Not a quality decision worth agonising
   * over here: it is what a webcam stream is tagged as, and the alternative
   * is dragging a colour-management dependency in for a video call. */
  for (y = 0; y < height; y++) {
    const unsigned char *Y = planes[0] + (size_t)y * sy;
    const unsigned char *U = planes[1] + (size_t)(y / 2) * su;
    const unsigned char *V = planes[2] + (size_t)(y / 2) * sv;
    unsigned char *dst = d->rgba + (size_t)y * width * 4;
    for (x = 0; x < width; x++) {
      int c = (int)Y[x] - 16;
      int u = (int)U[x / 2] - 128;
      int v = (int)V[x / 2] - 128;
      int r = (298 * c + 409 * v + 128) >> 8;
      int g = (298 * c - 100 * u - 208 * v + 128) >> 8;
      int b = (298 * c + 516 * u + 128) >> 8;
      dst[x * 4 + 0] = (unsigned char)(r < 0 ? 0 : r > 255 ? 255 : r);
      dst[x * 4 + 1] = (unsigned char)(g < 0 ? 0 : g > 255 ? 255 : g);
      dst[x * 4 + 2] = (unsigned char)(b < 0 ? 0 : b > 255 ? 255 : b);
      dst[x * 4 + 3] = 255;
    }
  }

  *out = d->rgba; *w = width; *h = height;
  return 0;
}

void frq_h264_decoder_close(void *handle) {
  frq_h264_dec *d = (frq_h264_dec *)handle;
  if (d == NULL) return;
  if (d->dec) { (*d->dec)->Uninitialize(d->dec); WelsDestroyDecoder(d->dec); }
  free(d->rgba);
  free(d);
}
