#import <Cocoa/Cocoa.h>

#import "CGFrameBuffer.h"

#import "AVMvidFileWriter.h"

#import "AVMvidFrameDecoder.h"

#include "maxvid_encode.h"

#import "qtencode.h"
#import "qtdecode.h"

#import <QTKit/QTKit.h>

#import <QuickTime/Movies.h>

CGSize _movieDimensions;

NSString *movie_prefix;

CGFrameBuffer *prevFrameBuffer = nil;

// Define this symbol to create a -test option that can be run from the command line.
#define TESTMODE

// Define to enable mode that will split the RGB+A into RGB and A in two different mvid files
#define SPLITALPHA

// A MovieOptions struct is filled in as the user passes
// specific command line options.

typedef struct
{
  float framerate;
  int   bpp;
  int   keyframe;
  BOOL  sRGB;
} MovieOptions;

// ------------------------------------------------------------------------
//
// mvidmoviemaker
//
// To convert a .mov to .mvid (Quicktime to optimized .mvid) execute.
//
// mvidmoviemaker movie.mov movie.mvid
//
// The following arguments can be used to create a .mvid video file
// from a series of PNG or other images. The -fps option indicates
// that the framerate is 15 frames per second. By default, the
// system will assume 24bpp "Millions". If input images make use
// of an alpha channel, then 32bpp "Millions+" will be used automatically.
//
// mvidmoviemaker FRAMES/Frame001.png movie.mvid -fps 15
//
// To extract the contents of an .mvid movie to PNG images:
//
// mvidmoviemaker -extract movie.mvid ?FILEPREFIX?"
//
// The optional FILEPREFIX should be specified as "DumpFile" to get
// frames files named "DumpFile0001.png" and "DumpFile0002.png" and so on.
//
//  To see a summary of MVID header info for a specific file.
//
//  mvidmoviemaker -info movie.mvid
// ------------------------------------------------------------------------

static
char *usageArray =
"usage: mvidmoviemaker INFILE.mov OUTFILE.mvid ?OPTIONS?" "\n"
"or   : mvidmoviemaker INFILE.mvid OUTFILE.mov ?OPTIONS?" "\n"
"or   : mvidmoviemaker FIRSTFRAME.png OUTFILE.mvid ?OPTIONS?" "\n"
"or   : mvidmoviemaker -extract FILE.mvid ?FILEPREFIX?" "\n"
"or   : mvidmoviemaker -info movie.mvid" "\n"
"or   : mvidmoviemaker -adler movie.mvid or movie.mov" "\n"
#if defined(SPLITALPHA)
"or   : mvidmoviemaker -splitalpha FILE.mvid (writes FILE_rgb.mvid and FILE_alpha.mvid)" "\n"
"or   : mvidmoviemaker -joinalpha FILE.mvid (reads FILE_rgb.mvid and FILE_alpha.mvid)" "\n"
#endif
"OPTIONS:\n"
"-fps FLOAT : required when creating .mvid from a series of images\n"
"-framerate FLOAT : alternative way to indicate 1.0/fps\n"
"-bpp INTEGER : 16, 24, or 32 (Thousands, Millions, Millions+)\n"
"-keyframe INTEGER : create a keyframe every N frames, 1 for all keyframes\n"
"-colorspace srgb|rgb : defaults to srgb, rgb indicates no colorspace mapping\n"
;

#define USAGE (char*)usageArray

// Create a CGImageRef given a filename. Image data is read from the file

CGImageRef createImageFromFile(NSString *filenameStr)
{
  CGImageSourceRef sourceRef;
  CGImageRef imageRef;
  
  if (FALSE) {
    // FIXME : values not the same after read from rgb24 -> rgb555 -> rbg24
    
    // This input PNG was downsampled from a smooth 24BPP gradient
    filenameStr = @"RGBGradient16BPP_SRGB.png";
  }
  
  if (FALSE) {
    filenameStr = @"SunriseFunkyColorspace.jpg";
  }
  
  if (FALSE) {
    filenameStr = @"RGBGradient24BPP_SRGB.png";
  }
  
  if (FALSE) {
    // Device RGB colorspace
    filenameStr = @"TestBlack.png";
  }
  
  if (FALSE) {
    filenameStr = @"TestOpaque.png";
  }
  
  if (FALSE) {
    filenameStr = @"TestAlphaOnOrOff.png";
  }
  
  if (FALSE) {
    filenameStr = @"TestAlpha.png";
  }

  if (FALSE) {
    filenameStr = @"Colorbands_sRGB.png";
  }
  
	NSData *image_data = [NSData dataWithContentsOfFile:filenameStr];
	if (image_data == nil) {
		fprintf(stderr, "can't read image data from file \"%s\"\n", [filenameStr UTF8String]);
		exit(1);
	}
  
	// Create image object from src image data.
  
  sourceRef = CGImageSourceCreateWithData((CFDataRef)image_data, NULL);
  
  // Make sure the image source exists before continuing
  
	if (sourceRef == NULL) {
		fprintf(stderr, "can't create image data from file \"%s\"\n", [filenameStr UTF8String]);
		exit(1);
	}
  
  // Create an image from the first item in the image source.
  
  imageRef = CGImageSourceCreateImageAtIndex(sourceRef, 0, NULL);
  
  CFRelease(sourceRef);
  
  return imageRef;
}

// Make a new MVID file writing object in the autorelease pool and configure
// with the indicated framerate, total number of frames, and bpp.

AVMvidFileWriter* makeMVidWriter(
                                 NSString *mvidFilename,
                                 NSUInteger bpp,
                                 NSTimeInterval frameRate,
                                 NSUInteger totalNumFrames
                                 )
{
  AVMvidFileWriter *mvidWriter = [AVMvidFileWriter aVMvidFileWriter];
  assert(mvidWriter);
  
  mvidWriter.mvidPath = mvidFilename;
  mvidWriter.bpp = bpp;
  // Note that we don't know the movie size until the first frame is read
  
  mvidWriter.frameDuration = frameRate;
  mvidWriter.totalNumFrames = totalNumFrames;
  
  mvidWriter.genAdler = TRUE;
  
  BOOL worked = [mvidWriter open];
  if (worked == FALSE) {
    fprintf(stderr, "error: Could not open .mvid output file \"%s\"\n", (char*)[mvidFilename UTF8String]);        
    exit(1);
  }
  
  return mvidWriter;
}

// This method is invoked with a path that contains the frame
// data and the offset into the frame array that this specific
// frame data is found at.
//
// mvidWriter  : Output destination for MVID frame data.
// filenameStr : Name of .png file that contains the frame data
// existingImageRef : If NULL, image is loaded from filenameStr instead
// frameIndex  : Frame index (starts at zero)
// bppNum      : 16, 24, or 32 BPP
// checkAlphaChannel : If bpp is 24 and this argument is TRUE, scan output pixels for non-opaque image.
// isKeyframe  : TRUE if this specific frame should be stored as a keyframe (as opposed to a delta frame)
// isSRGBColorspace : TRUE when writing pixels in the sRGB colorspace (the default), FALSE for device rgb.

int process_frame_file(AVMvidFileWriter *mvidWriter,
                       NSString *filenameStr,
                       CGImageRef existingImageRef,
                       int frameIndex,
                       int bppNum,
                       BOOL checkAlphaChannel,
                       BOOL isKeyframe,
                       BOOL isSRGBColorspace)
{
  // Push pool after creating global resources

  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  CGImageRef imageRef;
  if (existingImageRef == NULL) {
    imageRef = createImageFromFile(filenameStr);
  } else {
    imageRef = existingImageRef;
    CGImageRetain(imageRef);
  }
  assert(imageRef);
  
  // General logic is to assume sRGB colorspace since that is what the iOS device assumes.
  // If the user explicitly indicates -colorspace rgb then do no color convert the pixels.
  // But in general, we want to convert all the pixels to sRGB for all bpp values.
  //
  // SRGB
  // https://gist.github.com/1130831
  // http://www.mailinglistarchive.com/html/quartz-dev@lists.apple.com/2010-04/msg00076.html
  // http://www.w3.org/Graphics/Color/sRGB.html (see alpha masking topic)
  //
  // Render from input (RGB or whatever) into sRGB, this could involve conversions
  // but it makes the results portable and it basically better because it is still as
  // lossless as possible given the constraints. Only output sRGB and only work with
  // sRGB formatted data, perhaps a flag would be needed to reject images created by
  // earlier versions that don't use sRGB directly.
    
  CGSize imageSize = CGSizeMake(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef));
  int imageWidth = imageSize.width;
  int imageHeight = imageSize.height;

  assert(imageWidth > 0);
  assert(imageHeight > 0);
  
  // If this is the first frame, set the movie size based on the size of the first frame
  
  if (frameIndex == 0) {
    mvidWriter.movieSize = imageSize;
    _movieDimensions = imageSize;
  } else if (CGSizeEqualToSize(imageSize, _movieDimensions) == FALSE) {
    // Size of next frame must exactly match the size of the previous one
    
    fprintf(stderr, "error: frame file \"%s\" size %d x %d does not match initial frame size %d x %d\n",
            [filenameStr UTF8String],
            (int)imageSize.width, (int)imageSize.height,
            (int)_movieDimensions.width, (int)_movieDimensions.height);
    exit(2);
  }
    
  // Render input image into a CGFrameBuffer at a specific BPP. If the input buffer actually contains
  // 16bpp pixels expanded to 24bpp, then this render logic will resample down to 16bpp.

  if (bppNum == 24 && checkAlphaChannel) {
    bppNum = 32;
  }
  
  CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:imageWidth height:imageHeight];
  
  // Query the colorspace identified in the input PNG image
  
  BOOL useSRGBColorspace = FALSE;
    
  CGColorSpaceRef inputColorspace;
  inputColorspace = CGImageGetColorSpace(imageRef);
  // Should default to RGB if nothing is specified
  assert(inputColorspace);
  
  BOOL inputIsRGBColorspace = FALSE;
  
  /*
  {
    // CGColorSpaceCreateDeviceRGB();
    
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    
    NSString *colorspaceDescription = (NSString*) CGColorSpaceCopyName(colorspace);
    NSString *inputColorspaceDescription = (NSString*) CGColorSpaceCopyName(inputColorspace);
    
    if ([colorspaceDescription isEqualToString:inputColorspaceDescription]) {
      isRGBColorspace = TRUE;
    }
    
    CGColorSpaceRelease(colorspace);
  }
  */
  {
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    
    NSString *colorspaceDescription = (NSString*) CGColorSpaceCopyName(colorspace);
    NSString *inputColorspaceDescription = (NSString*) CGColorSpaceCopyName(inputColorspace);
    
    if ([colorspaceDescription isEqualToString:inputColorspaceDescription]) {
      inputIsRGBColorspace = TRUE;
    }

    CGColorSpaceRelease(colorspace);
    [colorspaceDescription release];
    [inputColorspaceDescription release];
  }

  BOOL inputIsSRGBColorspace = FALSE;
  {
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    
    NSString *colorspaceDescription = (NSString*) CGColorSpaceCopyName(colorspace);
    NSString *inputColorspaceDescription = (NSString*) CGColorSpaceCopyName(inputColorspace);
    
    if ([colorspaceDescription isEqualToString:inputColorspaceDescription]) {
      inputIsSRGBColorspace = TRUE;
    }
    
    CGColorSpaceRelease(colorspace);
    [colorspaceDescription release];
    [inputColorspaceDescription release];
  }
  
  if (inputIsRGBColorspace) {
    assert(inputIsSRGBColorspace == FALSE);
  }
  if (inputIsSRGBColorspace) {
    assert(inputIsRGBColorspace == FALSE);
  }
  
  // Output is either "device RGB" or "srgb"
  //
  // If input is in device RGB, and rgb is indicated, then keep device RGB.
  // If input is in device RGB, default, SRGB
  // If input is in sRGB, then use sRGB to avoid conversion

  //cgBuffer.colorspace = inputColorspace;
  
  // Always emit to sRGB colorspace unless the comamnd line options "-colorspace rgb" were passed.
  // The only reason to use this option is to binary compare the results, since the iOS device will
  // assume all input has already been mapped into the sRGB colorspace when reading pixel data.
  
//  if (bppNum == 24 || bppNum == 32) {
//    useSRGBColorspace = TRUE;
//  }
//  if (inputIsSRGBColorspace) {
//    useSRGBColorspace = TRUE;    
//  }
  
  if (isSRGBColorspace) {
    useSRGBColorspace = TRUE;
  }
  
  // Use sRGB colorspace when reading input pixels into format that will be written to
  // the .mvid file. This is needed when using a custom color space to avoid problems
  // related to storing the exact original input pixels.
  
  if (useSRGBColorspace) {
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    cgBuffer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);
    
    mvidWriter.isSRGB = TRUE;
  }
  
  BOOL worked = [cgBuffer renderCGImage:imageRef];
  assert(worked);
  
  CGImageRelease(imageRef);
    
  // Copy the pixels from the cgBuffer into a NSImage
  
  if (FALSE) {
    NSString *dumpFilename = [NSString stringWithFormat:@"WriteDumpFrame%0.4d.png", frameIndex+1];
    
    NSData *pngData = [cgBuffer formatAsPNG];
    
    [pngData writeToFile:dumpFilename atomically:NO];
    
    NSLog(@"wrote %@", dumpFilename);
  }
  
  // The CGFrameBuffer now contains the rendered pixels in the expected output format. Write to MVID frame.

  if (isKeyframe) {
    // Emit Keyframe
    
    char *buffer = cgBuffer.pixels;
    int bufferSize = cgBuffer.numBytes;
    int unPaddedBufferSize = cgBuffer.width * cgBuffer.height * cgBuffer.bytesPerPixel;
    
    worked = [mvidWriter writeKeyframe:buffer bufferSize:bufferSize unPaddedBufferSize:unPaddedBufferSize];
    
    if (worked == FALSE) {
      fprintf(stderr, "can't write keyframe data to mvid file \"%s\"\n", [filenameStr UTF8String]);
      exit(1);
    }    
  } else {
    // Calculate delta pixels by comparing the previous frame to the current frame.
    // Once we know specific delta pixels, then only those pixels that actually changed
    // can be stored in a delta frame.
    
    assert(prevFrameBuffer);
    
    NSData *encodedDeltaData;
    
    assert(prevFrameBuffer.width == cgBuffer.width);
    assert(prevFrameBuffer.height == cgBuffer.height);
    assert(prevFrameBuffer.bitsPerPixel == cgBuffer.bitsPerPixel);
    
    void *prevPixels = (void*)prevFrameBuffer.pixels;
    void *currentPixels = (void*)cgBuffer.pixels;
    int numWords;
    int width = cgBuffer.width;
    int height = cgBuffer.height;
    
    if (prevFrameBuffer.bitsPerPixel == 16) {
      numWords = cgBuffer.numBytes / sizeof(uint16_t);
      encodedDeltaData = maxvid_encode_generic_delta_pixels16(prevPixels,
                                                              currentPixels,
                                                              numWords,
                                                              width,
                                                              height);
      
    } else {
      numWords = cgBuffer.numBytes / sizeof(uint32_t);
      encodedDeltaData = maxvid_encode_generic_delta_pixels32(prevPixels,
                                                              currentPixels,
                                                              numWords,
                                                              width,
                                                              height);
    }
    
    if (encodedDeltaData == nil) {
      // The two frames are pixel identical, this is a no-op delta frame
      
      [mvidWriter writeNopFrame];
      worked = TRUE;
    } else {
      // Convert generic maxvid codes to c4 codes and emit as a data buffer
      
      void *pixelsPtr = (void*)cgBuffer.pixels;
      int inputBufferNumBytes = cgBuffer.numBytes;
      NSUInteger frameBufferNumPixels = width * height;
      
      worked = maxvid_write_delta_pixels(mvidWriter,
                                         encodedDeltaData,
                                         pixelsPtr,
                                         inputBufferNumBytes,
                                         frameBufferNumPixels);
    }
    
    if (worked == FALSE) {
      fprintf(stderr, "can't write deltaframe data to mvid file \"%s\"\n", [filenameStr UTF8String]);
      exit(1);
    }
  }

  // Wrote either keyframe, nop delta, or delta frame. In the case where we need to scan the pixels
  // to determine if any alpha channel pixels are used we might change the write bpp from 24 to 32 bpp.
  
  if (checkAlphaChannel) {
    uint32_t *currentPixels = (uint32_t*)cgBuffer.pixels;
    int width = cgBuffer.width;
    int height = cgBuffer.height;
    
    BOOL allOpaque = TRUE;
    
    for (int i=0; i < (width * height); i++) {
      uint32_t currentPixel = currentPixels[i];
      // ABGR
      uint8_t alpha = (currentPixel >> 24) & 0xFF;
      if (alpha != 0xFF) {
        allOpaque = FALSE;
        break;
      }
    }
    
    if (allOpaque == FALSE) {
      mvidWriter.bpp = 32;
    }
  }
  
  if (TRUE) {
    if (prevFrameBuffer) {
      [prevFrameBuffer release];
    }
    prevFrameBuffer = cgBuffer;
    [prevFrameBuffer retain];
  }
  
	// free up resources
  
  [pool drain];
	
	return 0;
}

// Extract all the frames of movie data from an archive file into
// files indicated by a path prefix.

void extractFramesFromMvidMain(char *mvidFilename, char *extractFramesPrefix) {
	BOOL worked;
  
  AVMvidFrameDecoder *frameDecoder = [AVMvidFrameDecoder aVMvidFrameDecoder];

	NSString *mvidPath = [NSString stringWithUTF8String:mvidFilename];
  
  worked = [frameDecoder openForReading:mvidPath];
  
  if (worked == FALSE) {
    fprintf(stderr, "error: cannot open mvid filename \"%s\"\n", mvidFilename);
    exit(1);
  }
    
  worked = [frameDecoder allocateDecodeResources];
  assert(worked);
  
  NSUInteger numFrames = [frameDecoder numFrames];
  assert(numFrames > 0);

  for (NSUInteger frameIndex = 0; frameIndex < numFrames; frameIndex++) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    AVFrame *frame = [frameDecoder advanceToFrame:frameIndex];
    assert(frame);
    
    // Release the NSImage ref inside the frame since we will operate on the CG image directly.
    frame.image = nil;
    
    CGFrameBuffer *cgFrameBuffer = frame.cgFrameBuffer;
    assert(cgFrameBuffer);
    
    if (frameDecoder.isSRGB) {
      // The frame decoder should have created the frame buffers using the sRGB colorspace.
      
      CGColorSpaceRef sRGBColorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      assert(sRGBColorspace == cgFrameBuffer.colorspace);
      CGColorSpaceRelease(sRGBColorspace);
    } else {
      assert(cgFrameBuffer.colorspace == NULL);      
    }
    
    NSData *pngData = [cgFrameBuffer formatAsPNG];
    assert(pngData);
    
    NSString *pngFilename = [NSString stringWithFormat:@"%s%0.4d%s", extractFramesPrefix, frameIndex+1, ".png"];
    
    [pngData writeToFile:pngFilename atomically:NO];
    
    NSString *dupString = @"";
    if (frame.isDuplicate) {
      dupString = @" (duplicate)";
    }
    
    NSLog(@"wrote %@%@", pngFilename, dupString);
    
    [pool drain];
  }

  [frameDecoder close];
  
	return;
}

// Return TRUE if file exists, FALSE otherwise

BOOL fileExists(NSString *filePath) {
  if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
    return TRUE;
	} else {
    return FALSE;
  }
}

// Entry point for logic that will extract video frames from a Quicktime .mov file
// and then write the frames as a .mvid file. The options argument is normally not
// used, but if the user indicated values then these values can overwrite defaults
// read from the input .mov file.

void encodeMvidFromMovMain(char *movFilenameCstr,
                           char *mvidFilenameCstr,
                           MovieOptions *optionsPtr)
{
  NSString *movFilename = [NSString stringWithUTF8String:movFilenameCstr];
  
  BOOL isMov = [movFilename hasSuffix:@".mov"];
  
  if (isMov == FALSE) {
    fprintf(stderr, "%s", USAGE);
    exit(1);
  }
  
  NSString *mvidFilename = [NSString stringWithUTF8String:mvidFilenameCstr];
  
  BOOL isMvid = [mvidFilename hasSuffix:@".mvid"];
  
  if (isMvid == FALSE) {
    fprintf(stderr, "%s", USAGE);
    exit(1);
  }
  
  if (fileExists(movFilename) == FALSE) {
    fprintf(stderr, "input quicktime movie file not found : %s\n", movFilenameCstr);
    exit(2);
  }

  BOOL worked;
  NSError *errState;  
  QTTime duration;
  QTTime startTime;
  QTTime currentTime;
  QTTime frameTime;
  CGImageRef frameImage;
  //int frameNum = 1;
  NSTimeInterval timeInterval;
  int mvidBPP = 24; // assume 24BPP at first, up to 32bpp if non-opaque pixels are found
  
  QTMovie *movie = [QTMovie movieWithFile:movFilename error:&errState];
  assert(movie);

  //NSDictionary *movieAttributes = [movie movieAttributes];
  //fprintf(stdout, "movieAttributes : %s", [[movieAttributes description] UTF8String]);
    
  BOOL done = FALSE;
  BOOL extractedFirstFrame = FALSE;
  
  duration = [[movie attributeForKey:QTMovieDurationAttribute] QTTimeValue];
  startTime = QTMakeTime(0, duration.timeScale);
  currentTime = startTime;
  
  // Iterate over the "interesting" times in the movie and calculate framerate.
  // Typically, the first couple of frames appear at the exact frame bound,
  // but then the times can be in flux depending on the movie. If the movie starts
  // with a very long frame display time but then a small frame rate appears
  // later on, we need to adjust the whole movie framerate to match the shortest
  // interval.

  TimeValue lastInteresting = 0;
  TimeValue nextInteresting;
	TimeValue nextInterestingDuration;
  short nextTimeFlags = nextTimeStep;
  QTTimeRange startEndRange = QTMakeTimeRange(startTime, duration);
  
  NSArray *tracks = [movie tracksOfMediaType:QTMediaTypeVideo];
  if ([tracks count] == 0) {
    fprintf(stderr, "Could not find any video tracks in movie file %s\n", movFilenameCstr);
    exit(2);
  }
  
  // FIXME: only descend into track looking for Animation codec if there is 1 video track
  
  QTTrack *firstTrack = [tracks objectAtIndex:0];
  QTMedia *firstTrackMedia = [firstTrack media];
  Media firstTrackQuicktimeMedia = [firstTrackMedia quickTimeMedia];
  assert(firstTrackQuicktimeMedia);

  //NSDictionary *firstTrackAttributes = [firstTrack trackAttributes];
  //fprintf(stdout, "firstTrackAttributes : %s\n", [[firstTrackAttributes description] UTF8String]);

  //NSDictionary *firstTrackMediaAttributes = [firstTrackMedia mediaAttributes];
  //fprintf(stdout, "firstTrackMediaAttributes : %s\n", [[firstTrackMediaAttributes description] UTF8String]);
  
  NSMutableArray *durations = [NSMutableArray array];
  
  if (TRUE) {
    // Drop into QT to determine what kind of samples are inside of the Media object
    
    ImageDescriptionHandle desc = (ImageDescriptionHandle)NewHandleClear(sizeof(ImageDescription));
        
    GetMediaSampleDescription(firstTrackQuicktimeMedia, 1, (SampleDescriptionHandle)desc);
    
    CodecType cType =(*desc)->cType;
    
    BOOL isAnimationCodec = FALSE;
    
    // Animation
    // 1919706400 ?= 'rle '
    char qtAniFourCC[] = { 'r', 'l', 'e', ' ' };
    uint32_t fourCC = qtAniFourCC[0] << 24 | qtAniFourCC[1] << 16 | qtAniFourCC[2] << 8 | qtAniFourCC[3];
    if (cType == fourCC) {
      isAnimationCodec = TRUE;
    }
    
    // Print an error message if the .mov file contains anything other than "Animation" codec data.
    
    if (isAnimationCodec == FALSE) {
      char c1 = (cType >> 24) & 0xFF;
      char c2 = (cType >> 16) & 0xFF;
      char c3 = (cType >> 8) & 0xFF;
      char c4 = (cType >> 0) & 0xFF;
      
      fprintf(stderr, "The .mov must contain Animation codec video data, not '%c%c%c%c'\n", c1, c2, c3, c4);
      exit(2);
    }
    
    int depth = (*desc)->depth;
    
    // When Animation codec declares the BPP as 32BPP, it is possible that an alpha channel will
    // be used. But it is also possible that the data could have been exported as "Millions+"
    // but it might not actually use the alpha channel. In this case, attempt to detect the
    // case of 24BPP in 32BPP pixels.
    
    if (depth == 16 || depth == 24 || depth == 32) {
      // No-op
    } else {
      fprintf(stderr, "The .mov Animation codec BPP must be 16, 24, or 32 bits, not %d\n", depth);
      exit(2);
    }
    
    // 16 (unlike 24 or 32, there is no alpha detection logic for 16 bpp).
    
    if (depth == 16) {
      mvidBPP = 16;
    }
    
    // For 16BPP Animation, we need to get at the data directly?
    
    // http://www.mailinglistarchive.com/quicktime-api@lists.apple.com/msg06593.html
    
    // http://svn.perian.org/trunk/MkvExportPrivate.cpp
    
    // http://developer.apple.com/library/mac/#documentation/QuickTime/Reference/QTRef_TrackAndMedia/Reference/reference.html
    
    // http://vasi.dyndns.info:3130/svn/QTSplit/QTKit+Extensions.m  *
    
    // https://helixbeta.org/projects/client/doxygen/hxclient_4_0_1_brizo/da/da9/QTVideoReader_8cpp-source.html
    
    DisposeHandle((Handle)desc);
  }
  
  fprintf(stdout, "extracting framerate from QT Movie\n");
    
  while (!done) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        
    GetMediaNextInterestingTime(firstTrackQuicktimeMedia,
                                nextTimeFlags,
                                (TimeValue)currentTime.timeValue,
                                1,
                                &nextInteresting,
                                &nextInterestingDuration);
    
    if (nextInteresting == -1) {      
      done = TRUE;
    } else {
      TimeValue interestingDuration = nextInteresting - lastInteresting;
      
      [durations addObject:[NSNumber numberWithInt:(int)interestingDuration]];
      
      currentTime = QTMakeTime(nextInteresting, duration.timeScale);
      
      worked = QTGetTimeInterval(currentTime, &timeInterval);
      assert(worked);
      
      fprintf(stdout, "found delta at time %f with duration %d\n", (float)timeInterval, (int)interestingDuration);
    }
    
    [pool drain];
  }
  if ([durations count] == 0) {
    // If one single frame is displayed for the entire length of the movie, then the
    // duration is the actual frame rate. The trouble with that approach is that
    // an animation is assumed to have at least 2 frames. Work around the assumption
    // by creating a framerate that is exactly half of the duration in this case.
    
    int halfDuration = (int)duration.timeValue / (int)2;
    NSNumber *halfDurationNum = [NSNumber numberWithInt:halfDuration];
    
    [durations addObject:halfDurationNum];
    [durations addObject:halfDurationNum];
  }
  
  assert([durations count] > 0);
  
  // First check for the easy case, where all the durations are the exact same number.
  
  int firstDuration = [[durations objectAtIndex:0] intValue];
  BOOL allSame = TRUE;
  int smallestDuration = firstDuration;
  for (NSNumber *durationNumber in durations) {
    int currentDuration = [durationNumber intValue];
    if (currentDuration != firstDuration) {
      allSame = FALSE;
    }
    if (currentDuration < smallestDuration) {
      smallestDuration = currentDuration;
    }
  }
  
  if (allSame) {
    frameTime = QTMakeTime(firstDuration, duration.timeScale);
  } else {
    // In the case where frame durations are different lengths, pick the smallest one.
    frameTime = QTMakeTime(smallestDuration, duration.timeScale);
  }
  
  // The frame interval is now known, so recalculate the total number of frames
  // by counting how many frames of the indicated interval fit into the movie duration.
    
  int totalNumFrames = 1;
  done = FALSE;
  currentTime = startTime;
  
  while (!done) {
    currentTime = QTTimeIncrement(currentTime, frameTime);
    
    // Done once at the end of the movie
    
    if (!QTTimeInTimeRange(currentTime, startEndRange)) {
      done = TRUE;
    } else {
      totalNumFrames++;
    }
  }
  
  // Now that we know the framerate, iterate through visual
  // display at the indicated framerate.
  // Calculate framerate in terms of clock time
  
  worked = QTGetTimeInterval(frameTime, &timeInterval);
  assert(worked);

  fprintf(stdout, "extracting %d frame(s) from QT Movie\n", totalNumFrames);
  fprintf(stdout, "frame duration is %f seconds\n", (float)timeInterval);
  fprintf(stdout, "movie pixels at %dBPP\n", mvidBPP);
  
  AVMvidFileWriter *mvidWriter = makeMVidWriter(mvidFilename, mvidBPP, timeInterval, totalNumFrames);
  
  setupMovFrameAtTime(movie, firstTrackMedia, mvidBPP);
  
  done = FALSE;
  currentTime = startTime;
  int frameIndex = 0;
  
  while (!done) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    worked = QTGetTimeInterval(currentTime, &timeInterval);
    assert(worked);
    
    frameImage = getMovFrameAtTime(currentTime);
    worked = (frameImage != nil);
        
    if (worked == FALSE) {
      done = TRUE;
      
      fprintf(stdout, "failed to extract frame %d at time %f\n", frameIndex+1, (float)timeInterval);
    } else {
      extractedFirstFrame = TRUE;
      
      fprintf(stdout, "extracted frame %d at time %f\n", frameIndex+1, (float)timeInterval);
      
      int width = CGImageGetWidth(frameImage);
      int height = CGImageGetHeight(frameImage);
      // Note that this value will always be 32bpp for a rendered movie frame, we need to
      // actually scan the pixels composited here to figure out if the alpha channel is used.
      int bpp = CGImageGetBitsPerPixel(frameImage);
      
      fprintf(stdout, "width x height : %d x %d at bpp %d\n", width, height, bpp);
      
      // Write frame data to MVID
      
      BOOL isKeyframe = FALSE;
      if (frameIndex == 0) {
        isKeyframe = TRUE;
      }
      
      BOOL checkAlphaChannel = FALSE;
      if (mvidBPP != 16) {
        if (optionsPtr->bpp == 24) {
          // Explicitly indicated "-bpp 24" so do not check for 32bpp pixels.
        } else {
          checkAlphaChannel = TRUE;          
        }
      }
      process_frame_file(mvidWriter, NULL, frameImage, frameIndex, mvidBPP, checkAlphaChannel, isKeyframe, optionsPtr->sRGB);
      frameIndex++;
    }
    
    // FIXME: need to evaluate how the QTTime maps to "real time" to deal with
    // the case where the fixed integer values do not map exactly the floating
    // point representation of time. Does adding a fixed QT time over and over
    // actually lead to round off error when converted to wall clock? Would the
    // emitted file get out of sync if the file was long enough?
    
    currentTime = QTTimeIncrement(currentTime, frameTime);
    
    // Done once at the end of the movie
    
    if (!QTTimeInTimeRange(currentTime, startEndRange)) {
      done = TRUE;
    }
    
    if (frameImage) {
      CGImageRelease(frameImage);
    }
    
    [pool drain];
  } // end while !done loop
  
  cleanupMovFrameAtTime();
  
  if (extractedFirstFrame == FALSE) {
    fprintf(stderr, "Could not extract initial frame from movie file %s\n", movFilenameCstr);
    exit(2);
  }
  
  assert(frameIndex == totalNumFrames);
  
  // Note that the process_frame_file() method could have modified the bpp field by changing it
  // from 24bpp to 32bpp in the case where alpha channel usage was found in the image data.
  // This call will rewrite the header with that updated info along with other data.
  
  [mvidWriter rewriteHeader];
  
  [mvidWriter close];
  
  fprintf(stdout, "done writing %d frames to %s\n", totalNumFrames, mvidFilenameCstr);
  fflush(stdout);
  
  // cleanup
  
  if (prevFrameBuffer) {
    [prevFrameBuffer release];
  }
  
  return;
}

// Entry point for logic that encodes a .mvid from a series of frames.

void encodeMvidFromFramesMain(char *mvidFilenameCstr,
                              char *firstFilenameCstr,
                              MovieOptions *optionsPtr)
{
  NSString *mvidFilename = [NSString stringWithUTF8String:mvidFilenameCstr];
  
  BOOL isMvid = [mvidFilename hasSuffix:@".mvid"];
  
  if (isMvid == FALSE) {
    fprintf(stderr, "%s", USAGE);
    exit(1);
  }
  
  // Given the first frame image filename, build and array of filenames
  // by checking to see if files exist up until we find one that does not.
  // This makes it possible to pass the 25th frame ofa 50 frame animation
  // and generate an animation 25 frames in duration.
  
  NSString *firstFilename = [NSString stringWithUTF8String:firstFilenameCstr];
  
  if (fileExists(firstFilename) == FALSE) {
    fprintf(stderr, "error: first filename \"%s\" does not exist\n", firstFilenameCstr);
    exit(1);
  }
  
  NSString *firstFilenameExt = [firstFilename pathExtension];
    
  // Find first numerical character in the [0-9] range starting at the end of the filename string.
  // A frame filename like "Frame0001.png" would be an example input. Note that the last frame
  // number must be the last character before the extension.
  
  NSArray *upToLastPathComponent = [firstFilename pathComponents];
  NSRange upToLastPathComponentRange;
  upToLastPathComponentRange.location = 0;
  upToLastPathComponentRange.length = [upToLastPathComponent count] - 1;
  upToLastPathComponent = [upToLastPathComponent subarrayWithRange:upToLastPathComponentRange];
  NSString *upToLastPathComponentPath = [NSString pathWithComponents:upToLastPathComponent];
  
  NSString *firstFilenameTail = [firstFilename lastPathComponent];
  NSString *firstFilenameTailNoExtension = [firstFilenameTail stringByDeletingPathExtension];
  
  int numericStartIndex = -1;
  BOOL foundNonAlpha = FALSE;
  
  for (int i = [firstFilenameTailNoExtension length] - 1; i > 0; i--) {
    unichar c = [firstFilenameTailNoExtension characterAtIndex:i];
    if ((c >= '0') && (c <= '9') && (foundNonAlpha == FALSE)) {
      numericStartIndex = i;
    } else {
      foundNonAlpha = TRUE;
    }
  }
  if (numericStartIndex == -1 || numericStartIndex == 0) {
    fprintf(stderr, "error: could not find frame number in first filename \"%s\"\n", firstFilenameCstr);
    exit(1);
  }
  
  // Extract the numeric portion of the first frame filename
  
  NSString *namePortion = [firstFilenameTailNoExtension substringToIndex:numericStartIndex];
  NSString *numberPortion = [firstFilenameTailNoExtension substringFromIndex:numericStartIndex];
  
  if ([namePortion length] < 1 || [numberPortion length] == 0) {
    fprintf(stderr, "error: could not find frame number in first filename \"%s\"\n", firstFilenameCstr);
    exit(1);
  }
  
  // Convert number with leading zeros to a simple integer
  
  NSMutableArray *inFramePaths = [NSMutableArray arrayWithCapacity:1024];
  
  int formatWidth = [numberPortion length];
  int startingFrameNumber = [numberPortion intValue];
  int endingFrameNumber = -1;
  
#define CRAZY_MAX_FRAMES 9999999
#define CRAZY_MAX_DIGITS 7
  
  // Note that we include the first frame in this loop just so that it gets added to inFramePaths.
  
  for (int i = startingFrameNumber; i < CRAZY_MAX_FRAMES; i++) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSMutableString *frameNumberWithLeadingZeros = [NSMutableString string];
    [frameNumberWithLeadingZeros appendFormat:@"%07d", i];
    if ([frameNumberWithLeadingZeros length] > formatWidth) {
      int numToDelete = [frameNumberWithLeadingZeros length] - formatWidth;
      NSRange delRange;
      delRange.location = 0;
      delRange.length = numToDelete;
      [frameNumberWithLeadingZeros deleteCharactersInRange:delRange];
      assert([frameNumberWithLeadingZeros length] == formatWidth);
    }
    [frameNumberWithLeadingZeros appendString:@"."];
    [frameNumberWithLeadingZeros appendString:firstFilenameExt];
    [frameNumberWithLeadingZeros insertString:namePortion atIndex:0];
    NSString *framePathWithNumber = [upToLastPathComponentPath stringByAppendingPathComponent:frameNumberWithLeadingZeros];
    
    if (fileExists(framePathWithNumber)) {
      // Found frame at indicated path, add it to array of known frame filenames
      
      [inFramePaths addObject:framePathWithNumber];
      endingFrameNumber = i;
    } else {
      // Frame filename with indicated frame number not found, done scanning for frame files
      [pool drain];
      break;
    }
    
    [pool drain];
  }

  if ([inFramePaths count] <= 1) {
    fprintf(stderr, "error: at least 2 input frames are required\n");
    exit(1);    
  }
  
  if ((startingFrameNumber == endingFrameNumber) || (endingFrameNumber == CRAZY_MAX_FRAMES-1)) {
    fprintf(stderr, "error: could not find last frame number\n");
    exit(1);
  }
  
  // FRAMERATE is a floating point number that indicates the delay between frames.
  // This framerate value is a constant that does not change over the course of the
  // movie, though it is possible that a certain frame could repeat a number of times.
  
  float framerateNum = optionsPtr->framerate;

  if (framerateNum <= 0.0f) {
    fprintf(stderr, "error: -framerate or -fps is required\n");
    exit(1);
  }
  
  // BITSPERPIXEL : 16, 24, or 32 BPP.
  
  int bppNum = optionsPtr->bpp;
  BOOL explicit24bpp = FALSE;
  
  // In the case where no -bpp is indicated on the command line, assume 24 bpp.
  // If the input data is actually 32 bpp then we can adjust upward.
  
  if (bppNum < 0) {
    bppNum = 24;
  } else if (bppNum == 24) {
    explicit24bpp = TRUE;
  }
  
  // KEYFRAME : integer that indicates a keyframe should be emitted every N frames
  
  int keyframeNum = optionsPtr->keyframe;
  if (keyframeNum == 0 || keyframeNum == 1) {
    // All frames as stored as keyframes. This takes up more space but the frames can
    // be blitted into graphics memory directly from mapped memory at runtime.
    keyframeNum = 0;
  } else if (keyframeNum < 0) {
    // Just revert to the default
    keyframeNum = 10000;
  }
  
  AVMvidFileWriter *mvidWriter = makeMVidWriter(mvidFilename, bppNum, framerateNum, [inFramePaths count]);
  
  // We now know the start and end integer values of the frame filename range.
  
  int frameIndex = 0;
  
  for (NSString *framePath in inFramePaths) {
    fprintf(stdout, "saved %s as frame %d\n", [framePath UTF8String], frameIndex+1);
    fflush(stdout);
    
    BOOL isKeyframe = FALSE;
    if (frameIndex == 0) {
      isKeyframe = TRUE;
    }
    if (keyframeNum == 0) {
      // All frames are key frames
      isKeyframe = TRUE;
    } else if ((keyframeNum > 0) && ((frameIndex % keyframeNum) == 0)) {
      // Keyframe every N frames
      isKeyframe = TRUE;
    }
    
    BOOL checkAlphaChannel = FALSE;
    if (bppNum != 16) {
      if (explicit24bpp == FALSE) {
        // If "-bpp 24" was passed, do not scan for alpha pixels. Instead, explicitly composite
        // over black to create a 24bpp movie from a 32bpp movie with an alpha channel.
        checkAlphaChannel = TRUE;
      }
    }
    process_frame_file(mvidWriter, framePath, NULL, frameIndex, bppNum, checkAlphaChannel, isKeyframe, optionsPtr->sRGB);
    frameIndex++;
  }
  
  // Done writing .mvid file
  
  [mvidWriter rewriteHeader];
  
  [mvidWriter close];
  
  fprintf(stdout, "done writing %d frames to %s\n", frameIndex, mvidFilenameCstr);
  fflush(stdout);
  
  // cleanup
  
  if (prevFrameBuffer) {
    [prevFrameBuffer release];
  }
}

void fprintStdoutFixedWidth(char *label)
{
  fprintf(stdout, "%-20s", label);
}

// Entry point for movie info printing logic. This will print the headers of the file
// and some encoding info.

void printMovieHeaderInfo(char *mvidFilenameCstr) {
  NSString *mvidFilename = [NSString stringWithUTF8String:mvidFilenameCstr];

  AVMvidFrameDecoder *frameDecoder = [AVMvidFrameDecoder aVMvidFrameDecoder];
  
  BOOL worked = [frameDecoder openForReading:mvidFilename];
  
  if (worked == FALSE) {
    fprintf(stderr, "error: cannot open mvid filename \"%s\"\n", mvidFilenameCstr);
    exit(1);
  }
  
  //worked = [frameDecoder allocateDecodeResources];
  //assert(worked);
  
  NSUInteger numFrames = [frameDecoder numFrames];
  assert(numFrames > 0);

  float frameDuration = [frameDecoder frameDuration];
  float movieDuration = frameDuration * numFrames;
  
  int bpp = [frameDecoder header]->bpp;
  
  // Format left side in fixed 20 space width
  
  fprintStdoutFixedWidth("MVID:");
  fprintf(stdout, "%s\n", [[mvidFilename lastPathComponent] UTF8String]);

  fprintStdoutFixedWidth("Width:");
  fprintf(stdout, "%d\n", [frameDecoder width]);
  
  fprintStdoutFixedWidth("Height:");
  fprintf(stdout, "%d\n", [frameDecoder height]);

  fprintStdoutFixedWidth("BitsPerPixel:");
  fprintf(stdout, "%d\n", bpp);

  fprintStdoutFixedWidth("ColorSpace:");
  if (frameDecoder.isSRGB) {
    fprintf(stdout, "%s\n", "sRGB");
  } else {
    fprintf(stdout, "%s\n", "RGB");    
  }

  fprintStdoutFixedWidth("Duration:");
  fprintf(stdout, "%.4fs\n", movieDuration);

  fprintStdoutFixedWidth("FrameDuration:");
  fprintf(stdout, "%.4fs\n", frameDuration);

  fprintStdoutFixedWidth("FPS:");
  fprintf(stdout, "%.4f\n", (1.0 / frameDuration));

  fprintStdoutFixedWidth("Frames:");
  fprintf(stdout, "%d\n", numFrames);
    
  [frameDecoder close];
}

// testmode() runs a series of basic test logic having to do with rendering
// and then checking the results of a graphics render operation.

#if defined(TESTMODE)

static inline
uint32_t rgba_to_bgra(uint8_t red, uint8_t green, uint8_t blue, uint8_t alpha)
{
  return (alpha << 24) | (red << 16) | (green << 8) | blue;
}

static inline
NSString* bgra_to_string(uint32_t pixel) {
  uint8_t alpha = (pixel >> 24) & 0xFF;
  uint8_t red = (pixel >> 16) & 0xFF;
  uint8_t green = (pixel >> 8) & 0xFF;
  uint8_t blue = (pixel >> 0) & 0xFF;
  return [NSString stringWithFormat:@"(%d, %d, %d, %d)", red, green, blue, alpha];
}

void testmode()
{
  // Create a framebuffer that contains a 75% gray color in 16bpp and device RGB
  
  @autoreleasepool
  {
    int bppNum = 16;
    int width = 2;
    int height = 2;
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    uint16_t *pixels = (uint16_t *)cgBuffer.pixels;
    int numPixels = width * height;
    
    uint32_t grayLevel = (int) (0x1F * 0.75);
    uint16_t grayPixel = (grayLevel << 10) | (grayLevel << 5) | grayLevel;
    
    for (int i=0; i < numPixels; i++) {
      pixels[i] = grayPixel;
    }
    
    // Create image from test data
    
    CGImageRef imageRef = [cgBuffer createCGImageRef];
    
    // Render test image into a new CGFrameBuffer and then verify that the pixel value is the same
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    [renderBuffer renderCGImage:imageRef];
    
    uint16_t *renderPixels = (uint16_t *)renderBuffer.pixels;
    
    for (int i=0; i < numPixels; i++) {
      uint16_t pixel = renderPixels[i];      
      assert(pixel == grayPixel);
    }
  }
  
  // Create a framebuffer that contains a 75% gray color in 24bpp and device RGB
  
  @autoreleasepool
  {
    int bppNum = 24;
    int width = 2;
    int height = 2;
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
   
    uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
    //int numBytes = cgBuffer.numBytes;
    int numPixels = width * height;
    int numBytes = numPixels * sizeof(uint32_t);

    uint32_t grayLevel = (int) (255 * 0.75);
    uint32_t grayPixel = rgba_to_bgra(grayLevel, grayLevel, grayLevel, 0xFF);
    
    for (int i=0; i < numPixels; i++) {
      pixels[i] = grayPixel;
    }
    
    // calculate alder
    
    uint32_t adler1 = maxvid_adler32(0L, (unsigned char *)pixels, numBytes);
    assert(adler1 != 0);
    
    // Create image from test data
    
    CGImageRef imageRef = [cgBuffer createCGImageRef];
    
    // Render test image into a new CGFrameBuffer and then verify that the pixel value is the same
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    [renderBuffer renderCGImage:imageRef];
    
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
    
    for (int i=0; i < numPixels; i++) {
      uint32_t pixel = renderPixels[i];      
      assert(pixel == grayPixel);
    }
    
    uint32_t adler2 = maxvid_adler32(0L, (unsigned char *)renderPixels, numBytes);
    assert(adler2 != 0);

    assert(adler1 == adler2);
  }
  
  // Create a framebuffer that contains a 75% gray color with alpha 0xFF in 32bpp and device RGB
  
  @autoreleasepool
  {
    int bppNum = 32;
    int width = 2;
    int height = 2;
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
    //int numBytes = cgBuffer.numBytes;
    int numPixels = width * height;
    //int numBytes = numPixels * sizeof(uint32_t);
    
    uint32_t grayLevel = (int) (255 * 0.75);
    uint32_t grayPixel = rgba_to_bgra(grayLevel, grayLevel, grayLevel, 0xFF);
    
    for (int i=0; i < numPixels; i++) {
      pixels[i] = grayPixel;
    }
    
    // Create image from test data
    
    CGImageRef imageRef = [cgBuffer createCGImageRef];
    
    // Render test image into a new CGFrameBuffer and then verify that the pixel value is the same
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    [renderBuffer renderCGImage:imageRef];
    
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
    
    for (int i=0; i < numPixels; i++) {
      uint32_t pixel = renderPixels[i];      
      assert(pixel == grayPixel);
    }
  }
  
  // Create a framebuffer that contains a 75% gray color with alpha 0.5 in 32bpp and device RGB
  
  @autoreleasepool
  {
    int bppNum = 32;
    int width = 2;
    int height = 2;
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
    //int numBytes = cgBuffer.numBytes;
    int numPixels = width * height;
    //int numBytes = numPixels * sizeof(uint32_t);
    
    uint32_t grayLevel = (int) (255 * 0.75);
    uint32_t grayPixel = rgba_to_bgra(grayLevel, grayLevel, grayLevel, 0xFF/2);
    
    for (int i=0; i < numPixels; i++) {
      pixels[i] = grayPixel;
    }
    
    // Create image from test data
    
    CGImageRef imageRef = [cgBuffer createCGImageRef];
    
    // Render test image into a new CGFrameBuffer and then verify that the pixel value is the same
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    [renderBuffer renderCGImage:imageRef];
    
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
    
    for (int i=0; i < numPixels; i++) {
      uint32_t pixel = renderPixels[i];      
      assert(pixel == grayPixel);
    }
  }
  
  // Create a framebuffer that contains all device RGB pixel values at 24 bpp

  @autoreleasepool
  {
    int bppNum = 24;
    int width = 256;
    int height = 3;
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
    //int numPixels = width * height;

    int offset = 0;

    for (int step=0; step < 256; step++) {
      uint32_t redPixel = rgba_to_bgra(step, 0, 0, 0xFF);      
      pixels[offset++] = redPixel;
    }

    for (int step=0; step < 256; step++) {
      uint32_t greenPixel = rgba_to_bgra(0, step, 0, 0xFF);      
      pixels[offset++] = greenPixel;
    }    

    for (int step=0; step < 256; step++) {
      uint32_t bluePixel = rgba_to_bgra(0, 0, step, 0xFF);      
      pixels[offset++] = bluePixel;
    }
    
    assert(offset == (256 * 3));
    
    // Create image from test data
    
    CGImageRef imageRef = [cgBuffer createCGImageRef];
    
    // Render test image into a new CGFrameBuffer and then verify that the pixel value is the same
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    [renderBuffer renderCGImage:imageRef];
    
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
    
    offset = 0;
    
    for (int step=0; step < 256; step++) {
      uint32_t redPixel = rgba_to_bgra(step, 0, 0, 0xFF);  
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == redPixel);
    }
    
    for (int step=0; step < 256; step++) {
      uint32_t greenPixel = rgba_to_bgra(0, step, 0, 0xFF);  
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == greenPixel);
    }    

    for (int step=0; step < 256; step++) {
      uint32_t bluePixel = rgba_to_bgra(0, 0, step, 0xFF);  
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == bluePixel);
    }
    
    assert(offset == (256 * 3));
  }

  // Create a framebuffer that contains all sRGB pixel values at 24 bpp
  
  @autoreleasepool
  {
    int bppNum = 24;
    int width = 256;
    int height = 3;
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];

    CGColorSpaceRef colorSpace;
    colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    assert(colorSpace);
    
    cgBuffer.colorspace = colorSpace;
    
    uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
    //int numPixels = width * height;
    
    int offset = 0;
    
    for (int step=0; step < 256; step++) {
      uint32_t redPixel = rgba_to_bgra(step, 0, 0, 0xFF);
      pixels[offset++] = redPixel;
    }
    
    for (int step=0; step < 256; step++) {
      uint32_t greenPixel = rgba_to_bgra(0, step, 0, 0xFF);
      pixels[offset++] = greenPixel;
    }    
    
    for (int step=0; step < 256; step++) {
      uint32_t bluePixel = rgba_to_bgra(0, 0, step, 0xFF);
      pixels[offset++] = bluePixel;
    }
    
    assert(offset == (256 * 3));
    
    // Create image from test data
    
    CGImageRef imageRef = [cgBuffer createCGImageRef];
    
    // Render test image into a new CGFrameBuffer and then verify that the pixel value is the same
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    renderBuffer.colorspace = colorSpace;
    CGColorSpaceRelease(colorSpace);
    
    [renderBuffer renderCGImage:imageRef];
        
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
    
    offset = 0;
    
    for (int step=0; step < 256; step++) {
      uint32_t redPixel = rgba_to_bgra(step, 0, 0, 0xFF);  
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == redPixel);
    }
    
    for (int step=0; step < 256; step++) {
      uint32_t greenPixel = rgba_to_bgra(0, step, 0, 0xFF);  
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == greenPixel);
    }    
    
    for (int step=0; step < 256; step++) {
      uint32_t bluePixel = rgba_to_bgra(0, 0, step, 0xFF);  
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == bluePixel);
    }
    
    assert(offset == (256 * 3));
  }
  
  // Create a framebuffer that contains device RGB pixel values with an alpha step at 32bpp
  
  @autoreleasepool
  {
    int bppNum = 32;
    int width = 256;
    int height = 3;
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
    
    int offset = 0;
    
    for (int step=0; step < 256; step++) {
      uint32_t redPixel = rgba_to_bgra(0xFF, 0, 0, step);
      pixels[offset++] = redPixel;
    }
    
    for (int step=0; step < 256; step++) {
      uint32_t greenPixel = rgba_to_bgra(0, 0xFF, 0, step);
      pixels[offset++] = greenPixel;
    }    
    
    for (int step=0; step < 256; step++) {
      uint32_t bluePixel = rgba_to_bgra(0, 0, 0xFF, step);
      pixels[offset++] = bluePixel;
    }
    
    assert(offset == (256 * 3));
    
    // Create image from test data
    
    CGImageRef imageRef = [cgBuffer createCGImageRef];
    
    // Render test image into a new CGFrameBuffer and then verify that the pixel value is the same
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    [renderBuffer renderCGImage:imageRef];
    
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
    
    offset = 0;
    
    for (int step=0; step < 256; step++) {
      uint32_t redPixel = rgba_to_bgra(0xFF, 0, 0, step);
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == redPixel);
    }
    
    for (int step=0; step < 256; step++) {
      uint32_t greenPixel = rgba_to_bgra(0, 0xFF, 0, step);
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == greenPixel);
    }    
    
    for (int step=0; step < 256; step++) {
      uint32_t bluePixel = rgba_to_bgra(0, 0, 0xFF, step);
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == bluePixel);
    }
    
    assert(offset == (256 * 3));
  }

  // Create a framebuffer that contains sRGB pixel values with an alpha step at 32bpp
  
  @autoreleasepool
  {
    int bppNum = 32;
    int width = 256;
    int height = 3;
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    CGColorSpaceRef colorSpace;
    colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    assert(colorSpace);
    
    cgBuffer.colorspace = colorSpace;
    
    uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
    
    int offset = 0;
    
    for (int step=0; step < 256; step++) {
      uint32_t redPixel = rgba_to_bgra(0xFF, 0, 0, step);
      pixels[offset++] = redPixel;
    }
    
    for (int step=0; step < 256; step++) {
      uint32_t greenPixel = rgba_to_bgra(0, 0xFF, 0, step);
      pixels[offset++] = greenPixel;
    }    
    
    for (int step=0; step < 256; step++) {
      uint32_t bluePixel = rgba_to_bgra(0, 0, 0xFF, step);
      pixels[offset++] = bluePixel;
    }
    
    assert(offset == (256 * 3));
    
    // Create image from test data
    
    CGImageRef imageRef = [cgBuffer createCGImageRef];
    
    // Render test image into a new CGFrameBuffer and then verify that the pixel value is the same
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    renderBuffer.colorspace = colorSpace;
    CGColorSpaceRelease(colorSpace);
    
    [renderBuffer renderCGImage:imageRef];
    
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
    
    offset = 0;
    
    for (int step=0; step < 256; step++) {
      uint32_t redPixel = rgba_to_bgra(0xFF, 0, 0, step);
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == redPixel);
    }
    
    for (int step=0; step < 256; step++) {
      uint32_t greenPixel = rgba_to_bgra(0, 0xFF, 0, step);
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == greenPixel);
    }    
    
    for (int step=0; step < 256; step++) {
      uint32_t bluePixel = rgba_to_bgra(0, 0, 0xFF, step);
      uint32_t pixel = renderPixels[offset++];
      assert(pixel == bluePixel);
    }
    
    assert(offset == (256 * 3));
  }
  
  /*
  
  // This test case will create a 1x4 RGB with the pixels (RED, GREEN, BLUE, GRAY)
  // where gray component is 50% gray. These pixels will then be converted to the
  // sRGB colorspace and then back to RGB to make sure the SRGB -> RGB is actually
  // reversing the mapping into sRGB colosspace.
  
  @autoreleasepool
  {
    int bppNum = 24;
    int width = 4;
    int height = 1;
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
   
    CGColorSpaceRef rgbColorSpace;
    rgbColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    assert(rgbColorSpace);
    cgBuffer.colorspace = rgbColorSpace;
    CGColorSpaceRelease(rgbColorSpace);
    
    uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
    
    pixels[0] = rgba_to_bgra(0xFF, 0, 0, 0xFF);
    pixels[1] = rgba_to_bgra(0, 0xFF, 0, 0xFF);
    pixels[2] = rgba_to_bgra(0, 0, 0xFF, 0xFF);
    pixels[3] = rgba_to_bgra(0xFF/2, 0xFF/2, 0xFF/2, 0xFF);
    
    uint32_t redPixel = pixels[0];
    uint32_t greenPixel = pixels[1];
    uint32_t bluePixel = pixels[2];
    uint32_t grayPixel = pixels[3];
    
    NSString *redStr = bgra_to_string(redPixel);
    NSString *greenStr = bgra_to_string(greenPixel);
    NSString *blueStr = bgra_to_string(bluePixel);
    NSString *grayStr = bgra_to_string(grayPixel);
    
    assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
    assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
    assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
    assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
        
    // Create image from test data
    
    CGImageRef imageRef = [cgBuffer createCGImageRef];
    
    // Render test image into a new CGFrameBuffer in sRGB colorspace and then examine pixel values.
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    CGColorSpaceRef srgbColorSpace;
    srgbColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    renderBuffer.colorspace = srgbColorSpace;
    CGColorSpaceRelease(srgbColorSpace);
    
    [renderBuffer renderCGImage:imageRef];
    CGImageRelease(imageRef);
    
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;

    redPixel = renderPixels[0];
    greenPixel = renderPixels[1];
    bluePixel = renderPixels[2];
    grayPixel = renderPixels[3];
    
    redStr = bgra_to_string(redPixel);
    greenStr = bgra_to_string(greenPixel);
    blueStr = bgra_to_string(bluePixel);
    grayStr = bgra_to_string(grayPixel);
    
    // sRGB values are shifted
    
    assert([redStr isEqualToString:@"(255, 38, 0, 255)"]);
    assert([greenStr isEqualToString:@"(0, 249, 0, 255)"]);
    assert([blueStr isEqualToString:@"(4, 51, 255, 255)"]);
    assert([grayStr isEqualToString:@"(145, 145, 145, 255)"]);
    
    // Emit "RedGreenBlueGray_sRGB.png"
    
    if (TRUE) {
      NSString *filename = @"RedGreenBlueGray_sRGB.png";
      
      NSData *pngData = [renderBuffer formatAsPNG];
      
      [pngData writeToFile:filename atomically:NO];
      
      NSLog(@"wrote %@", filename);
    }
    
    // Now attempt to convert the sRGB values back to GenericRGB to see if the pixel values match.
    
    assert(cgBuffer.isLockedByDataProvider == FALSE);
    memset(cgBuffer.pixels, 0, cgBuffer.numBytes);
    
    imageRef = [renderBuffer createCGImageRef];
    
    [cgBuffer renderCGImage:imageRef];
    CGImageRelease(imageRef);

    redPixel = pixels[0];
    greenPixel = pixels[1];
    bluePixel = pixels[2];
    grayPixel = pixels[3];
    
    redStr = bgra_to_string(redPixel);
    greenStr = bgra_to_string(greenPixel);
    blueStr = bgra_to_string(bluePixel);
    grayStr = bgra_to_string(grayPixel);
    
    assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
    assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
    assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
    assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
    
    // Emit "RedGreenBlueGray_RGB.png"
    
    if (TRUE) {
      NSString *filename = @"RedGreenBlueGray_RGB.png";
      
      NSData *pngData = [cgBuffer formatAsPNG];
      
      [pngData writeToFile:filename atomically:NO];
      
      NSLog(@"wrote %@", filename);
    }
  }
   
  */
  
  /*
  
  // This test case will load a 1x4 image from a file on disk. When a file is not tagged
  // with a specific profile, it defaults to a generic RGB profile. This test attempts
  // to determine if loading from a file leads to different results when rendering into
  // sRGB vs setting data directly into a pixel array. One immediate diff to note is
  // that kCGColorSpaceDeviceRGB is the colorspace for a file loaded from disk that has
  // no specific colorspace while the generic RGB profile is actually a profile that can
  // be attached to a file.
  
  @autoreleasepool
  {
    int bppNum = 24;
    int width = 4;
    int height = 1;
    
    // Load "RedGreenBlueGray_RawRGB.png";
    
    NSString *filename;
    
    //filename = @"RedGreenBlueGray_RawRGB.png";
    filename = @"RedGreenBlueGray_Gimp.bmp";
    
    CGImageRef imageRef = createImageFromFile(filename);
    assert(imageRef);
    
    assert(width == CGImageGetWidth(imageRef));
    assert(height == CGImageGetHeight(imageRef));
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    // When no colorspace is applied to an image, it is loaded with "kCGColorSpaceDeviceRGB"
    
    CGColorSpaceRef rgbColorSpace;
    //rgbColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    rgbColorSpace = CGImageGetColorSpace(imageRef);
    assert(rgbColorSpace);
    cgBuffer.colorspace = rgbColorSpace;
    CGColorSpaceRelease(rgbColorSpace);
    
    [cgBuffer renderCGImage:imageRef];
    
    uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
        
    uint32_t redPixel = pixels[0];
    uint32_t greenPixel = pixels[1];
    uint32_t bluePixel = pixels[2];
    uint32_t grayPixel = pixels[3];
    
    NSString *redStr = bgra_to_string(redPixel);
    NSString *greenStr = bgra_to_string(greenPixel);
    NSString *blueStr = bgra_to_string(bluePixel);
    NSString *grayStr = bgra_to_string(grayPixel);
    
    assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
    assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
    assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
    assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
    
    // Create image from test data
    
    if (FALSE) {
      CGImageRelease(imageRef);
      imageRef = [cgBuffer createCGImageRef];
    }
    
    // Render test image into a new CGFrameBuffer in sRGB colorspace and then examine pixel values.
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    CGColorSpaceRef srgbColorSpace;
    srgbColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    renderBuffer.colorspace = srgbColorSpace;
    CGColorSpaceRelease(srgbColorSpace);
    
    [renderBuffer renderCGImage:imageRef];
    CGImageRelease(imageRef);
    
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
    
    redPixel = renderPixels[0];
    greenPixel = renderPixels[1];
    bluePixel = renderPixels[2];
    grayPixel = renderPixels[3];
    
    redStr = bgra_to_string(redPixel);
    greenStr = bgra_to_string(greenPixel);
    blueStr = bgra_to_string(bluePixel);
    grayStr = bgra_to_string(grayPixel);
    
    // sRGB values are shifted, not the same as conversion from "Generic RGB"
    
    if (TRUE) {
    assert([redStr isEqualToString:@"(233, 63, 51, 255)"]);
    assert([greenStr isEqualToString:@"(128, 242, 0, 255)"]);
    assert([blueStr isEqualToString:@"(0, 72, 251, 255)"]);
    assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
    }
    
    // Now attempt to convert the sRGB values back to GenericRGB to see if the pixel values match.
    
    assert(cgBuffer.isLockedByDataProvider == FALSE);
    memset(cgBuffer.pixels, 0, cgBuffer.numBytes);
    
    imageRef = [renderBuffer createCGImageRef];
    
    [cgBuffer renderCGImage:imageRef];
    CGImageRelease(imageRef);
    
    redPixel = pixels[0];
    greenPixel = pixels[1];
    bluePixel = pixels[2];
    grayPixel = pixels[3];
    
    redStr = bgra_to_string(redPixel);
    greenStr = bgra_to_string(greenPixel);
    blueStr = bgra_to_string(bluePixel);
    grayStr = bgra_to_string(grayPixel);
    
    if (TRUE) {
      // Write file that contains the results converting from device RGB to sRGB then back to device RGB
      
      if (TRUE) {
        NSString *filename = @"RedGreenBlueGray_Device2SRGB.png";
        
        NSData *pngData = [cgBuffer formatAsPNG];
        
        [pngData writeToFile:filename atomically:NO];
        
        NSLog(@"wrote %@", filename);
      }

    }
    
    assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
    assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
    assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
    assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);    
  }
  
  */
  
  /*
  
  // This test case defines an in memory buffer that contains the same results as
  // would be loaded from RedGreenBlueGray_Gimp.bmp. Loading from a BMP will
  // not use a specific colorspace, instead the device profile would be attached
  // automatically by the system. Loading the exact same pixel data with the
  // same colorspace means a test case can run without an external file.
  
  @autoreleasepool
  {
    int bppNum = 24;
    int width = 4;
    int height = 1;
    
    CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    CGColorSpaceRef rgbColorSpace;
    rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    assert(rgbColorSpace);
    cgBuffer.colorspace = rgbColorSpace;
    CGColorSpaceRelease(rgbColorSpace);
    
    uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
    
    pixels[0] = rgba_to_bgra(0xFF, 0, 0, 0xFF);
    pixels[1] = rgba_to_bgra(0, 0xFF, 0, 0xFF);
    pixels[2] = rgba_to_bgra(0, 0, 0xFF, 0xFF);
    pixels[3] = rgba_to_bgra(0xFF/2, 0xFF/2, 0xFF/2, 0xFF);
    
    uint32_t redPixel = pixels[0];
    uint32_t greenPixel = pixels[1];
    uint32_t bluePixel = pixels[2];
    uint32_t grayPixel = pixels[3];
    
    NSString *redStr = bgra_to_string(redPixel);
    NSString *greenStr = bgra_to_string(greenPixel);
    NSString *blueStr = bgra_to_string(bluePixel);
    NSString *grayStr = bgra_to_string(grayPixel);
    
    assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
    assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
    assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
    assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
    
    // Render test image into a new CGFrameBuffer in sRGB colorspace and then examine pixel values.
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    CGColorSpaceRef srgbColorSpace;
    srgbColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    renderBuffer.colorspace = srgbColorSpace;
    CGColorSpaceRelease(srgbColorSpace);

    CGImageRef imageRef;
    imageRef = [cgBuffer createCGImageRef];
    [renderBuffer renderCGImage:imageRef];
    CGImageRelease(imageRef);
    
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
    
    redPixel = renderPixels[0];
    greenPixel = renderPixels[1];
    bluePixel = renderPixels[2];
    grayPixel = renderPixels[3];
    
    redStr = bgra_to_string(redPixel);
    greenStr = bgra_to_string(greenPixel);
    blueStr = bgra_to_string(bluePixel);
    grayStr = bgra_to_string(grayPixel);
    
    // sRGB values are shifted, not the same as conversion from "Generic RGB"
    
    if (TRUE) {
      assert([redStr isEqualToString:@"(233, 63, 51, 255)"]);
      assert([greenStr isEqualToString:@"(128, 242, 0, 255)"]);
      assert([blueStr isEqualToString:@"(0, 72, 251, 255)"]);
      assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
    }
    
    // Now attempt to convert the sRGB values back to GenericRGB to see if the pixel values match.
    
    assert(cgBuffer.isLockedByDataProvider == FALSE);
    memset(cgBuffer.pixels, 0, cgBuffer.numBytes);
    
    imageRef = [renderBuffer createCGImageRef];
    
    [cgBuffer renderCGImage:imageRef];
    CGImageRelease(imageRef);
    
    redPixel = pixels[0];
    greenPixel = pixels[1];
    bluePixel = pixels[2];
    grayPixel = pixels[3];
    
    redStr = bgra_to_string(redPixel);
    greenStr = bgra_to_string(greenPixel);
    blueStr = bgra_to_string(bluePixel);
    grayStr = bgra_to_string(grayPixel);
    
    if (FALSE) {
      // Write file that contains the results converting from device RGB to sRGB then back to device RGB
      
      if (TRUE) {
        NSString *filename = @"RedGreenBlueGray_Device2SRGB.png";
        
        NSData *pngData = [cgBuffer formatAsPNG];
        
        [pngData writeToFile:filename atomically:NO];
        
        NSLog(@"wrote %@", filename);
      }
      
    }
    
    assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
    assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
    assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
    assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
  }
  
  */

  /*
  
  // This test case attempts to work around issues related to conversion from
  // DeviceRGB to sRGB by detecting when DeviceRGB is being used by default
  // for untagged content. First, this code will convert from DeviceRGB
  // to GenericRGB and then to sRGB. If we can then convert from sRGB back
  // to GenericRGB without losing information then that approach could be
  // used to avoid color shift on untagged content.
  
  // This test case was not useful. Conversion from RGB To GenericRGB also
  // changed the RGB values in a non-reversable way.
   
  @autoreleasepool
  {
    int bppNum = 24;
    int width = 4;
    int height = 1;
    
    uint32_t redPixel;
    uint32_t greenPixel;
    uint32_t bluePixel;
    uint32_t grayPixel;
    
    NSString *redStr;
    NSString *greenStr;
    NSString *blueStr;
    NSString *grayStr;
    
    CGColorSpaceRef imageRefColorspace;
    
    CGFrameBuffer *deviceRGBBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    CGColorSpaceRef deviceRGBColorSpace;
    deviceRGBColorSpace = CGColorSpaceCreateDeviceRGB();
    assert(deviceRGBColorSpace);
    deviceRGBBuffer.colorspace = deviceRGBColorSpace;
    CGColorSpaceRelease(deviceRGBColorSpace);
    
    uint32_t *pixels = (uint32_t *)deviceRGBBuffer.pixels;
    
    pixels[0] = rgba_to_bgra(0xFF, 0, 0, 0xFF);
    pixels[1] = rgba_to_bgra(0, 0xFF, 0, 0xFF);
    pixels[2] = rgba_to_bgra(0, 0, 0xFF, 0xFF);
    pixels[3] = rgba_to_bgra(0xFF/2, 0xFF/2, 0xFF/2, 0xFF);
    
    redPixel = pixels[0];
    greenPixel = pixels[1];
    bluePixel = pixels[2];
    grayPixel = pixels[3];
    
    redStr = bgra_to_string(redPixel);
    greenStr = bgra_to_string(greenPixel);
    blueStr = bgra_to_string(bluePixel);
    grayStr = bgra_to_string(grayPixel);
    
    assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
    assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
    assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
    assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
    
    // Render deviceRGBBuffer into genericRGBBuffer

    CGFrameBuffer *genericRGBBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    CGColorSpaceRef genericRGBColorSpace;
    genericRGBColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    assert(genericRGBColorSpace);
    genericRGBBuffer.colorspace = genericRGBColorSpace;
    CGColorSpaceRelease(genericRGBColorSpace);
    
    CGImageRef imageRef;
    imageRef = [deviceRGBBuffer createCGImageRef];
    
    // The colorspace defined in the image must match deviceRGBColorSpace
    imageRefColorspace = CGImageGetColorSpace(imageRef);
    assert(deviceRGBColorSpace == imageRefColorspace);
    
    [genericRGBBuffer renderCGImage:imageRef];
    CGImageRelease(imageRef);
    
    uint32_t *genericRGBPixels = (uint32_t *)genericRGBBuffer.pixels;
    
    redPixel = genericRGBPixels[0];
    greenPixel = genericRGBPixels[1];
    bluePixel = genericRGBPixels[2];
    grayPixel = genericRGBPixels[3];
    
    redStr = bgra_to_string(redPixel);
    greenStr = bgra_to_string(greenPixel);
    blueStr = bgra_to_string(bluePixel);
    grayStr = bgra_to_string(grayPixel);
    
    if (FALSE) {
      
//       Unclear why these values come out this way!
//       (lldb) po redStr
//       (NSString *) $7 = 0x001126f0 (225, 39, 40, 255)
//       (lldb) po greenStr
//       (NSString *) $8 = 0x0030dc00 (113, 245, 5, 255)
//       (lldb) po blueStr
//       (NSString *) $9 = 0x001131b0 (0, 41, 250, 255)
//       (lldb) po grayStr
//       (NSString *) $10 = 0x00113350 (108, 108, 108, 255)
      
    assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
    assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
    assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
    assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
    }
    
    // Render test image into a new CGFrameBuffer in sRGB colorspace and then examine pixel values.
    
    CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    CGColorSpaceRef srgbColorSpace;
    srgbColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    renderBuffer.colorspace = srgbColorSpace;
    CGColorSpaceRelease(srgbColorSpace);
    
    imageRef = [genericRGBBuffer createCGImageRef];
    
    // The colorspace defined in the image must match genericRGBColorSpace
    imageRefColorspace = CGImageGetColorSpace(imageRef);
    assert(genericRGBColorSpace == imageRefColorspace);
    
    [renderBuffer renderCGImage:imageRef];
    CGImageRelease(imageRef);
    
    uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
    
    redPixel = renderPixels[0];
    greenPixel = renderPixels[1];
    bluePixel = renderPixels[2];
    grayPixel = renderPixels[3];
    
    redStr = bgra_to_string(redPixel);
    greenStr = bgra_to_string(greenPixel);
    blueStr = bgra_to_string(bluePixel);
    grayStr = bgra_to_string(grayPixel);
    
    // sRGB values are shifted, not the same as conversion from "Generic RGB"
    
    if (TRUE) {
      assert([redStr isEqualToString:@"(233, 63, 51, 255)"]);
      assert([greenStr isEqualToString:@"(128, 242, 0, 255)"]);
      assert([blueStr isEqualToString:@"(0, 72, 251, 255)"]);
      assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
    }
    
    // Now attempt to convert the sRGB values back to GenericRGB to see if the pixel values match.
    
    assert(genericRGBBuffer.isLockedByDataProvider == FALSE);
    memset(genericRGBBuffer.pixels, 0, genericRGBBuffer.numBytes);
    
    imageRef = [renderBuffer createCGImageRef];
    
    [genericRGBBuffer renderCGImage:imageRef];
    CGImageRelease(imageRef);
    
    redPixel = pixels[0];
    greenPixel = pixels[1];
    bluePixel = pixels[2];
    grayPixel = pixels[3];
    
    redStr = bgra_to_string(redPixel);
    greenStr = bgra_to_string(greenPixel);
    blueStr = bgra_to_string(bluePixel);
    grayStr = bgra_to_string(grayPixel);
    
    if (FALSE) {
      // Write file that contains the results converting from device RGB to sRGB then back to device RGB
      
      if (TRUE) {
        NSString *filename = @"RedGreenBlueGray_Device2SRGB.png";
        
        NSData *pngData = [genericRGBBuffer formatAsPNG];
        
        [pngData writeToFile:filename atomically:NO];
        
        NSLog(@"wrote %@", filename);
      }
      
    }
    
    assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
    assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
    assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
    assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
  }
  
  */

  // This test case will create a 1x4 RGB with the pixels (RED, GREEN, BLUE, GRAY)
  // where gray component is 50% gray. These pixels are converted from and to the
  // RGB linear colorspace with a 1.0 gamma.
  
  /*
   @autoreleasepool
   {
   int bppNum = 24;
   int width = 4;
   int height = 1;
   
   CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
   
   CGColorSpaceRef rgbColorSpace;
   rgbColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGBLinear);
   assert(rgbColorSpace);
   cgBuffer.colorspace = rgbColorSpace;
   CGColorSpaceRelease(rgbColorSpace);
   
   uint32_t *pixels = (uint32_t *)cgBuffer.pixels;
   
   pixels[0] = rgba_to_bgra(0xFF, 0, 0, 0xFF);
   pixels[1] = rgba_to_bgra(0, 0xFF, 0, 0xFF);
   pixels[2] = rgba_to_bgra(0, 0, 0xFF, 0xFF);
   pixels[3] = rgba_to_bgra(0xFF/2, 0xFF/2, 0xFF/2, 0xFF);
   
   uint32_t redPixel = pixels[0];
   uint32_t greenPixel = pixels[1];
   uint32_t bluePixel = pixels[2];
   uint32_t grayPixel = pixels[3];
   
   NSString *redStr = bgra_to_string(redPixel);
   NSString *greenStr = bgra_to_string(greenPixel);
   NSString *blueStr = bgra_to_string(bluePixel);
   NSString *grayStr = bgra_to_string(grayPixel);
   
   assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
   assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
   assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
   assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
   
   // Create image from test data
   
   CGImageRef imageRef = [cgBuffer createCGImageRef];
   
   // Render test image into a new CGFrameBuffer in sRGB colorspace and then examine pixel values.
   
   CGFrameBuffer *renderBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
   
   CGColorSpaceRef srgbColorSpace;
   srgbColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
   renderBuffer.colorspace = srgbColorSpace;
   CGColorSpaceRelease(srgbColorSpace);
   
   [renderBuffer renderCGImage:imageRef];
   CGImageRelease(imageRef);
   
   uint32_t *renderPixels = (uint32_t *)renderBuffer.pixels;
   
   redPixel = renderPixels[0];
   greenPixel = renderPixels[1];
   bluePixel = renderPixels[2];
   grayPixel = renderPixels[3];
   
   redStr = bgra_to_string(redPixel);
   greenStr = bgra_to_string(greenPixel);
   blueStr = bgra_to_string(bluePixel);
   grayStr = bgra_to_string(grayPixel);
   
   // sRGB values are shifted
   
   assert([redStr isEqualToString:@"(255, 39, 0, 255)"]);
   assert([greenStr isEqualToString:@"(0, 249, 0, 255)"]);
   assert([blueStr isEqualToString:@"(10, 49, 255, 255)"]);
   assert([grayStr isEqualToString:@"(187, 187, 187, 255)"]);
   
   // Now attempt to convert the sRGB values back to GenericRGBLeanear to see if the pixel values match.
   
   assert(cgBuffer.isLockedByDataProvider == FALSE);
   memset(cgBuffer.pixels, 0, cgBuffer.numBytes);
   
   imageRef = [renderBuffer createCGImageRef];
   
   [cgBuffer renderCGImage:imageRef];
   CGImageRelease(imageRef);
   
   redPixel = pixels[0];
   greenPixel = pixels[1];
   bluePixel = pixels[2];
   grayPixel = pixels[3];
   
   redStr = bgra_to_string(redPixel);
   greenStr = bgra_to_string(greenPixel);
   blueStr = bgra_to_string(bluePixel);
   grayStr = bgra_to_string(grayPixel);
   
   assert([redStr isEqualToString:@"(255, 0, 0, 255)"]);
   assert([greenStr isEqualToString:@"(0, 255, 0, 255)"]);
   assert([blueStr isEqualToString:@"(0, 0, 255, 255)"]);
   assert([grayStr isEqualToString:@"(127, 127, 127, 255)"]);
   }
  */
  
  return;
}
#endif // TESTMODE

#if defined(SPLITALPHA)

void
splitalpha(char *mvidFilenameCstr)
{
	NSString *mvidPath = [NSString stringWithUTF8String:mvidFilenameCstr];
  
  BOOL isMvid = [mvidPath hasSuffix:@".mvid"];
  
  if (isMvid == FALSE) {
    fprintf(stderr, "%s", USAGE);
    exit(1);
  }

  // Create "xyz_rgb.mvid" and "xyz_alpha.mvid" output filenames
  
  NSString *mvidFilename = [mvidPath lastPathComponent];
  NSString *mvidFilenameNoExtension = [mvidFilename stringByDeletingPathExtension];

  NSString *rgbFilename = [NSString stringWithFormat:@"%@_rgb.mvid", mvidFilenameNoExtension];
  NSString *alphaFilename = [NSString stringWithFormat:@"%@_alpha.mvid", mvidFilenameNoExtension];
  
  // Read in frames from input file, then split the RGB and ALPHA components such that
  // the premultiplied color values are writted to one file and the ALPHA (grayscale)
  // values are written to the other.
  
  AVMvidFrameDecoder *frameDecoder = [AVMvidFrameDecoder aVMvidFrameDecoder];
  
  BOOL worked = [frameDecoder openForReading:mvidPath];
  
  if (worked == FALSE) {
    fprintf(stderr, "error: cannot open mvid filename \"%s\"\n", mvidFilenameCstr);
    exit(1);
  }
  
  worked = [frameDecoder allocateDecodeResources];
  assert(worked);
  
  NSUInteger numFrames = [frameDecoder numFrames];
  assert(numFrames > 0);
  
  float frameDuration = [frameDecoder frameDuration];
  
  int bpp = [frameDecoder header]->bpp;
  
  int width = [frameDecoder width];
  int height = [frameDecoder height];
  
  if (bpp != 32) {
    fprintf(stderr, "%s\n", "-splitalpha can only be used on a 32BPP MVID movie");
    exit(1);
  }

  // Verify that the input color data has been mapped to the sRGB colorspace.
  
  if ([frameDecoder isSRGB] == FALSE) {
    fprintf(stderr, "%s\n", "-splitalpha can only be used on MVID movie in the sRGB colorspace");
    exit(1);
  }
  
  // Writer that will write the RGB values
  
  AVMvidFileWriter *rgbWriter = makeMVidWriter(rgbFilename, 24, frameDuration, numFrames);
  
  rgbWriter.movieSize = CGSizeMake(width, height);
  rgbWriter.isSRGB = TRUE;
  
  // Writer that will write the ALPHA values as grayscale

  AVMvidFileWriter *alphaWriter = makeMVidWriter(alphaFilename, 24, frameDuration, numFrames);
  
  alphaWriter.movieSize = CGSizeMake(width, height);
  alphaWriter.isSRGB = TRUE;

  // Loop over each frame, split RGB and ALPHA data into two framebuffers
  
  CGFrameBuffer *rgbFrameBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:24 width:width height:height];
  CGFrameBuffer *alphaFrameBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:24 width:width height:height];
  
  for (NSUInteger frameIndex = 0; frameIndex < numFrames; frameIndex++) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    AVFrame *frame = [frameDecoder advanceToFrame:frameIndex];
    assert(frame);
    
    // Release the NSImage ref inside the frame since we will operate on the CG image directly.
    frame.image = nil;
    
    CGFrameBuffer *cgFrameBuffer = frame.cgFrameBuffer;
    assert(cgFrameBuffer);

    // sRGB
    
    if (frameIndex == 0) {
      rgbFrameBuffer.colorspace = cgFrameBuffer.colorspace;
      alphaFrameBuffer.colorspace = cgFrameBuffer.colorspace;
    }
    
    // Split RGB and ALPHA
    
    NSUInteger numPixels = cgFrameBuffer.width * cgFrameBuffer.height;
    uint32_t *pixels = (uint32_t*)cgFrameBuffer.pixels;
    uint32_t *rgbPixels = (uint32_t*)rgbFrameBuffer.pixels;
    uint32_t *alphaPixels = (uint32_t*)alphaFrameBuffer.pixels;
    
    for (NSUInteger pixeli = 0; pixeli < numPixels; pixeli++) {
      uint32_t pixel = pixels[pixeli];
      
      uint32_t alpha = (pixel >> 24) & 0xFF;
      
      uint32_t alphaPixel = (alpha << 16) | (alpha << 8) | alpha;
      
      alphaPixels[pixeli] = alphaPixel;
      
      uint32_t rgbPixel = pixel & 0xFFFFFF;
      
      rgbPixels[pixeli] = rgbPixel;
    }
    
    // Note that the buffer size passed in includes and zero padded pixels at
    // the end of the buffer.
    
    assert(rgbFrameBuffer.numBytes == alphaFrameBuffer.numBytes);
    int bufferSize = rgbFrameBuffer.numBytes;
    int unPaddedBufferSize = numPixels * rgbFrameBuffer.bytesPerPixel;
    
    // Write RGB framebuffer
    
    [rgbWriter writeKeyframe:(char*)rgbPixels bufferSize:bufferSize unPaddedBufferSize:unPaddedBufferSize];

    // Write A framebuffer
    
    [alphaWriter writeKeyframe:(char*)alphaPixels bufferSize:bufferSize unPaddedBufferSize:unPaddedBufferSize];
    
    [pool drain];
  }
  
  [rgbWriter rewriteHeader];
  [rgbWriter close];
  
  [alphaWriter rewriteHeader];
  [alphaWriter close];
  
  NSLog(@"Wrote %@", rgbWriter.mvidPath);
  NSLog(@"Wrote %@", alphaWriter.mvidPath);
  
  return;
}

void
joinalpha(char *mvidFilenameCstr)
{
	NSString *mvidPath = [NSString stringWithUTF8String:mvidFilenameCstr];
  
  BOOL isMvid = [mvidPath hasSuffix:@".mvid"];
  
  if (isMvid == FALSE) {
    fprintf(stderr, "%s", USAGE);
    exit(1);
  }

  // The join alpha logic needs to be able to find FILE_rgb.mvid and FILE_alpha.mvid
  // in the same directory as FILE.mvid
  
  NSString *mvidFilename = [mvidPath lastPathComponent];
  NSString *mvidFilenameNoExtension = [mvidFilename stringByDeletingPathExtension];
  
  NSString *rgbFilename = [NSString stringWithFormat:@"%@_rgb.mvid", mvidFilenameNoExtension];
  NSString *alphaFilename = [NSString stringWithFormat:@"%@_alpha.mvid", mvidFilenameNoExtension];
  
  // Reconstruct the fully qualified path for the RGB and ALPHA filenames
  
  NSArray *mvidPathComponents = [mvidPath pathComponents];
  assert(mvidPathComponents);
  
  NSArray *pathPrefixComponents = [NSArray array];
  if ([mvidPathComponents count] > 1) {
    NSRange range;
    range.location = 0;
    range.length = [mvidPathComponents count] - 1;
    pathPrefixComponents = [mvidPathComponents subarrayWithRange:range];
  }
  NSString *pathPrefix = nil;
  if ([pathPrefixComponents count] > 0) {
    pathPrefix = [NSString pathWithComponents:pathPrefixComponents];
  }
  
  NSString *rgbPath = rgbFilename;
  if (pathPrefix != nil) {
    rgbPath = [pathPrefix stringByAppendingPathComponent:rgbFilename];
  }

  NSString *alphaPath = alphaFilename;
  if (pathPrefix != nil) {
    alphaPath = [pathPrefix stringByAppendingPathComponent:alphaFilename];
  }
  
  if (fileExists(rgbPath) == FALSE) {
    fprintf(stderr, "Cannot find input RGB file %s\n", [rgbPath UTF8String]);
    exit(1);
  }

  if (fileExists(alphaPath) == FALSE) {
    fprintf(stderr, "Cannot find input ALPHA file %s\n", [alphaPath UTF8String]);
    exit(1);
  }
  
  // Remove output file if it exists
  
  if (fileExists(mvidPath) == FALSE) {
    [[NSFileManager defaultManager] removeItemAtPath:mvidPath error:nil];
  }
  
  // Open both the rgb and alpha mvid files for reading
  
  AVMvidFrameDecoder *frameDecoderRGB = [AVMvidFrameDecoder aVMvidFrameDecoder];
  AVMvidFrameDecoder *frameDecoderAlpha = [AVMvidFrameDecoder aVMvidFrameDecoder];
  
  BOOL worked;
  worked = [frameDecoderRGB openForReading:rgbPath];
  
  if (worked == FALSE) {
    fprintf(stderr, "error: cannot open RGB mvid filename \"%s\"\n", [rgbPath UTF8String]);
    exit(1);
  }
  
  if ([frameDecoderRGB isSRGB] == FALSE) {
    fprintf(stderr, "%s\n", "-joinalpha can only be used with a SRGB input MVID movie");
    exit(1);
  }

  worked = [frameDecoderAlpha openForReading:alphaPath];
  
  if (worked == FALSE) {
    fprintf(stderr, "error: cannot open RGB mvid filename \"%s\"\n", [alphaPath UTF8String]);
    exit(1);
  }
  
  if ([frameDecoderAlpha isSRGB] == FALSE) {
    fprintf(stderr, "%s\n", "-joinalpha can only be used with a SRGB input MVID movie");
    exit(1);
  }
    
  [frameDecoderRGB allocateDecodeResources];
  [frameDecoderAlpha allocateDecodeResources];
  
  // Create output file writer object
  
  NSTimeInterval frameRate = frameDecoderRGB.frameDuration;
  NSUInteger numFrames = [frameDecoderRGB numFrames];
  int width = [frameDecoderRGB width];
  int height = [frameDecoderRGB height];
  CGSize size = CGSizeMake(width, height);
  
  // Size of Alpha movie must match size of RGB movie
  
  CGSize alphaMovieSize;
  
  alphaMovieSize = CGSizeMake(frameDecoderAlpha.width, frameDecoderAlpha.height);
  if (CGSizeEqualToSize(size, alphaMovieSize) == FALSE) {
    fprintf(stderr, "RGB movie size (%d, %d) does not match alpha movie size (%d, %d)\n",
            (int)width, (int)height,
            (int)alphaMovieSize.width, (int)alphaMovieSize.height);
    exit(1);
  }
  
  AVMvidFileWriter *fileWriter = makeMVidWriter(mvidPath, 32, frameRate, numFrames);

  fileWriter.movieSize = size;
  fileWriter.isSRGB = TRUE;
  
  CGFrameBuffer *combinedFrameBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:32 width:width height:height];
  
  for (NSUInteger frameIndex = 0; frameIndex < numFrames; frameIndex++) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // FIXME: Each input frame should be 24 BPP
    
    AVFrame *frameRGB = [frameDecoderRGB advanceToFrame:frameIndex];
    assert(frameRGB);

    AVFrame *frameAlpha = [frameDecoderAlpha advanceToFrame:frameIndex];
    assert(frameAlpha);
    
    // Release the NSImage ref inside the frame since we will operate on the CG image directly.
    frameRGB.image = nil;
    frameAlpha.image = nil;
    
    CGFrameBuffer *cgFrameBufferRGB = frameRGB.cgFrameBuffer;
    assert(cgFrameBufferRGB);
    
    CGFrameBuffer *cgFrameBufferAlpha = frameAlpha.cgFrameBuffer;
    assert(cgFrameBufferAlpha);

    int bpp;
    
    bpp = cgFrameBufferRGB.bitsPerPixel;
    if (bpp != 24) {
      fprintf(stderr, "-joinalpha can only be used with a 24BPP MVID input movie (not %d bpp)\n", bpp);
      exit(1);
    }
    
    bpp = cgFrameBufferAlpha.bitsPerPixel;
    if (bpp != 24) {
      fprintf(stderr, "-joinalpha can only be used with a 24BPP MVID input movie (not %d bpp)\n", bpp);
      exit(1);
    }
    
    // sRGB
    
    if (frameIndex == 0) {
      combinedFrameBuffer.colorspace = cgFrameBufferRGB.colorspace;
    }
    
    // Join RGB and ALPHA
    
    NSUInteger numPixels = width * height;
    uint32_t *combinedPixels = (uint32_t*)combinedFrameBuffer.pixels;
    uint32_t *rgbPixels = (uint32_t*)cgFrameBufferRGB.pixels;
    uint32_t *alphaPixels = (uint32_t*)cgFrameBufferAlpha.pixels;
    
    for (NSUInteger pixeli = 0; pixeli < numPixels; pixeli++) {
      uint32_t pixelAlpha = alphaPixels[pixeli];
      
      // All 3 components of the ALPHA pixel need to be the same.

      uint32_t pixelAlphaRed = (pixelAlpha >> 16) & 0xFF;
      uint32_t pixelAlphaGreen = (pixelAlpha >> 8) & 0xFF;
      uint32_t pixelAlphaBlue = (pixelAlpha >> 0) & 0xFF;
      
      if (pixelAlphaRed != pixelAlphaGreen || pixelAlphaRed != pixelAlphaBlue) {
        fprintf(stderr, "Input Alpha MVID input movie R G B components do not match at pixel %d in frame %d\n", pixeli, frameIndex);
        exit(1);
      }
      
      // RGB componenets are 24 BPP premultiplied
      
      uint32_t pixelRGB = rgbPixels[pixeli];
      
      pixelRGB = pixelRGB & 0xFFFFFF;
      
      uint32_t combinedPixel = (pixelAlphaRed << 24) | pixelRGB;
      
      combinedPixels[pixeli] = combinedPixel;
    }
    
    // FIXME: This output method could be improved by using the general purpose "emit and detect"
    // logic that is able to compress delta frames down. Currently, a joined RGBA movie is very
    // large because the output frames are always written as keyframes. Not critical.
    
    // Note that the buffer size passed in includes and zero padded pixels at
    // the end of the buffer.
    
    int bufferSize = combinedFrameBuffer.numBytes;
    int unPaddedBufferSize = combinedFrameBuffer.width * combinedFrameBuffer.height * combinedFrameBuffer.bytesPerPixel;
    
    // Write combined RGBA pixles
    
    [fileWriter writeKeyframe:(char*)combinedPixels bufferSize:bufferSize unPaddedBufferSize:unPaddedBufferSize];
    
    [pool drain];
  }
  
  [fileWriter rewriteHeader];
  [fileWriter close];
  
  NSLog(@"Wrote %@", fileWriter.mvidPath);
  return;
}

#endif // SPLITALPHA

// This method will iterate through all the frames defined in a .mvid file and
// print out the adler32 checksum for the video data in the specific frame.
// With an mvid file, this checksum is already created at the time the .mvid
// file is created, so this function is trivial to implement since we just
// iterate over the frames and print the values.

// private properties declaration for class AVMvidFrameDecoder, used here
// to implete looking directly into the file header.

@interface AVMvidFrameDecoder ()
@property (nonatomic, assign) MVFrame *mvFrames;
@end

void printMvidFrameAdler(NSString *mvidFilename)
{
	BOOL worked;
  
  AVMvidFrameDecoder *frameDecoder = [AVMvidFrameDecoder aVMvidFrameDecoder];
  
  worked = [frameDecoder openForReading:mvidFilename];
  
  if (worked == FALSE) {
    fprintf(stderr, "error: cannot open mvid filename \"%s\"\n", [mvidFilename UTF8String]);
    exit(1);
  }
  
  worked = [frameDecoder allocateDecodeResources];
  assert(worked);
  
  NSUInteger numFrames = [frameDecoder numFrames];
  assert(numFrames > 0);
  
  //fprintf(stdout, "%s\n", [[mvidFilename lastPathComponent] UTF8String]);
  
  MVFrame *mvFrames = frameDecoder.mvFrames;
  assert(mvFrames);
  
  uint32_t lastAdler = 0x0;
  
  for (NSUInteger frameIndex = 0; frameIndex < numFrames; frameIndex++) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    MVFrame *frame = maxvid_file_frame(mvFrames, frameIndex);
    assert(frame);
    
    uint32_t currentAdler = frame->adler;

    if (maxvid_frame_isnopframe(frame)) {
      currentAdler = lastAdler;
    } else {
      lastAdler = currentAdler;
    }
    
    fprintf(stdout, "0x%X\n", currentAdler);
    
    [pool drain];
  }
  
  [frameDecoder close];
  
	return;
}

// This method will iterate over the images defined in a .mov and then calculate
// an adler32 checksum for the uncompressed video data. Then, this checksum is
// printed out one line for each frame. This logic enables to comparison of
// decompressed image data so that it is possible to know if the conversion to
// .mov format is working as expected. In addition, it makes testing possible
// since the adler output of a .mov file can be compared to the same adler
// output for a .mvid file to determine if the video data contants match.

void printMovFrameAdler(NSString *movFilename)
{
  // Convert the .mvid input file to a tmp.mvid file that we will then run printMvidFrameAdler
  // on to print out the decoded adler values. This conversion logic ensures that we get the
  // exact pixel values that the decoding logic would convert to.
  
  MovieOptions options;
  options.framerate = 1.0f;
  //options.bpp = 32;
  options.bpp = -1;
  options.keyframe = 10000;
  options.sRGB = TRUE;
  
  NSString *tmpFilename = @"_tmp.mvid";
  
  if (fileExists(tmpFilename)) {
    [[NSFileManager defaultManager] removeItemAtPath:tmpFilename error:nil];
  }
  
  @autoreleasepool {
    encodeMvidFromMovMain((char*)[movFilename UTF8String], (char*)[tmpFilename UTF8String], &options);
    printMvidFrameAdler(tmpFilename);
  }
  
  if (fileExists(tmpFilename)) {
    [[NSFileManager defaultManager] removeItemAtPath:tmpFilename error:nil];
  }  
}

// main() Entry Point

int main (int argc, const char * argv[]) {
	NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
  
	if ((argc == 3 || argc == 4) && (strcmp(argv[1], "-extract") == 0)) {
		// Extract movie frames from an existing archive

    char *mvidFilename = (char *)argv[2];
    char *framesFilePrefix;
    
    if (argc == 3) {
      framesFilePrefix = "Frame";
    } else {
      framesFilePrefix = (char*)argv[3];
    }
    
		extractFramesFromMvidMain(mvidFilename, framesFilePrefix);
	} else if ((argc == 3) && (strcmp(argv[1], "-info") == 0)) {
    // mvidmoviemaker -info movie.mvid
    
    char *mvidFilename = (char *)argv[2];
    
    printMovieHeaderInfo(mvidFilename);
	} else if ((argc == 3) && (strcmp(argv[1], "-adler") == 0)) {
    // mvidmoviemaker -info movie.mvid
    // mvidmoviemaker -info movie.mov
    
    char *firstFilenameCstr = (char*)argv[2];
    NSString *firstFilenameStr = [NSString stringWithUTF8String:firstFilenameCstr];
    
    if ([firstFilenameStr hasSuffix:@".mvid"])
    {
      printMvidFrameAdler(firstFilenameStr);
      exit(0);
    } else if ([firstFilenameStr hasSuffix:@".mov"]) {
      printMovFrameAdler(firstFilenameStr);
      exit(0);
    } else {
      fprintf(stderr, "error: FILENAME must be a .mvid or .mov file : %s\n", firstFilenameCstr);
      exit(1);
    }
#if defined(TESTMODE)
	} else if (argc == 2 && (strcmp(argv[1], "-test") == 0)) {
    testmode();
#endif // TESTMODE
#if defined(SPLITALPHA)
	} else if (argc == 3 && (strcmp(argv[1], "-splitalpha") == 0)) {
    // mvidmoviemaker -splitalpha INFILE.mvid
    char *mvidFilenameCstr = (char*)argv[2];
    splitalpha(mvidFilenameCstr);
	} else if (argc == 3 && (strcmp(argv[1], "-joinalpha") == 0)) {
    // mvidmoviemaker -joinalpha OUTFILE.mvid
    char *mvidFilenameCstr = (char*)argv[2];
    joinalpha(mvidFilenameCstr);
#endif // SPLITALPHA
  } else if (argc >= 3) {
    // Either:
    //
    // mvidmoviemaker INFILE.mov OUTFILE.mvid ?OPTIONS?
    // mvidmoviemaker INFILE.mvid OUTFILE.mov ?OPTIONS?
    // mvidmoviemaker FIRSTFRAME.png OUTFILE.mvid ?OPTIONS?
    
    char *firstFilenameCstr = (char*)argv[1];
    char *secondFilenameCstr = (char*)argv[2];
    
    if (TRUE) {
      fprintf(stderr, "%s\n", firstFilenameCstr);
      fprintf(stderr, "%s\n", secondFilenameCstr);
    }
    
    NSString *firstFilenameStr = [NSString stringWithUTF8String:firstFilenameCstr];
    NSString *secondFilenameStr = [NSString stringWithUTF8String:secondFilenameCstr];
    
    // If the arguments are INFILE.mvid OUTFILE.mvid, then convert video data
    // back to Quicktime format and write to a new movie file.
    
    if ([firstFilenameStr hasSuffix:@".mvid"] && [secondFilenameStr hasSuffix:@".mov"])
    {
      @autoreleasepool {
        convertMvidToMov(firstFilenameStr, secondFilenameStr);
      }
      exit(0);
    }

    char *mvidFilenameCstr = secondFilenameCstr;
    
    // The second argument has to be "*.mvid"
    
    NSString *mvidFilename = [NSString stringWithUTF8String:mvidFilenameCstr];
    
    BOOL isMvid = [mvidFilename hasSuffix:@".mvid"];
    
    if (isMvid == FALSE) {
      fprintf(stderr, "%s", USAGE);
      exit(1);
    }

    // If the first argument is a .mov file, then this must be
    // a .mov -> .mvid conversion.
    
    NSString *movFilename = [NSString stringWithUTF8String:firstFilenameCstr];
    
    BOOL isMov = [movFilename hasSuffix:@".mov"];
    
    // Both forms support 1 to N arguments like "-fps 15"
    
    MovieOptions options;
    options.framerate = 0.0f;
    options.bpp = -1;
    options.keyframe = 10000;
    options.sRGB = TRUE;
    
    if ((argc > 3) && (((argc - 3) % 2) != 0)) {
      // Uneven number of options
      fprintf(stderr, "error: OPTIONS must be an even number arguments of the form -name value\n");
      exit(1);
    } else if (argc > 3) {
      // Parse OPTIONS
      
      int pairCount = (argc - 3) / 2;
      
      for (int i=0; i<pairCount; i++) {
        int offset = 3 + (i * 2);
        char *optionCstr = (char*)argv[offset];
        char *valueCstr = (char*)argv[offset+1];
        
        NSString *optionStr = [NSString stringWithUTF8String:optionCstr];
        NSString *valueStr = [NSString stringWithUTF8String:valueCstr];
        
        NSLog(@"option \"%s\" -> \"%s\"", optionCstr, valueCstr);
        
        if ([optionStr isEqualToString:@"-fps"]) {
          float fps = [valueStr floatValue];
          
          if ((fps <= 0.0f) || (fps >= 90.0f)) {
            fprintf(stderr, "%s", USAGE);
            exit(1);
          }
          
          options.framerate = 1.0 / fps;
        } else if ([optionStr isEqualToString:@"-framerate"]) {
          float framerate = [valueStr floatValue];
                    
          if (framerate <= 0.0f || framerate >= 90.0f) {
            fprintf(stderr, "error: -framerate is invalid \"%f\"\n", framerate);
            exit(1);
          }

          options.framerate = framerate;
        } else if ([optionStr isEqualToString:@"-bpp"]) {
          int bpp = [valueStr intValue];
          
          if ((bpp == 16) || (bpp == 24) || (bpp == 32)) {
            // No-op
          } else {
            fprintf(stderr, "error: -bpp is invalid \"%s\"\n", valueCstr);
            exit(1);
          }
          
          options.bpp = bpp;
        } else if ([optionStr isEqualToString:@"-keyframe"]) {
          int keyframe = [valueStr intValue];
          
          if (keyframe <= 0) {
            fprintf(stderr, "%s", USAGE);
            exit(1);
          }
          
          options.keyframe = keyframe;
        } else if ([optionStr isEqualToString:@"-colorspace"]) {
          if ([valueStr isEqualToString:@"rgb"]) {
            options.sRGB = FALSE;
          } else if ([valueStr isEqualToString:@"srgb"]) {
            options.sRGB = TRUE;
          } else {
            fprintf(stderr, "error: -colorspace is invalid \"%s\"\n", valueCstr);
            exit(1);
          }
        } else {
          // Unmatched option
          
          fprintf(stderr, "error: option %s is invalid\n", optionCstr);
          exit(1);
        }
      }
    }    
    
    if (isMov) {
      // INFILE.mov : name of input Quicktime .mov file
      // OUTFILE.mvid : name of output .mvid file
      //
      // When converting, the original BPP and framerate are copied
      // but only the initial keyframe remains a keyframe in the .mvid
      // file for reasons of space savings.
      
      encodeMvidFromMovMain(firstFilenameCstr, mvidFilenameCstr, &options);
      
      if (TRUE) {
        // Extract frames we just encoded into the .mvid file for debug purposes
        
        extractFramesFromMvidMain(mvidFilenameCstr, "ExtractedFrame");
      }
      
      if (TRUE) {
        printMovieHeaderInfo(mvidFilenameCstr);
      }
    } else {
      // Otherwise, generate a .mvid from a series of images
      
      // FIRSTFRAME.png : name of first frame file of input PNG files. All
      //   video frames must exist in the same directory      
      // FILE.mvid : name of output file that will contain all the video frames
      
      // Either -framerate FLOAT or -fps FLOAT is required when build from frames.
      // -fps 15, -fps 29.97, -fps 30 are common values.
      
      // -bpp is optional, the default is 24 but 32 bpp will be detected if used.
      // If -bpp 16 is indicated then the result pixels will be downsamples from
      // 24 bpp to 16 bpp if the input source is in 24 bpp.
      
      encodeMvidFromFramesMain(mvidFilenameCstr,
                               firstFilenameCstr,
                               &options);
      
      if (TRUE) {
        // Extract frames we just encoded into the .mvid file for debug purposes
        
        extractFramesFromMvidMain(mvidFilenameCstr, "ExtractedFrame");
      }
      
      if (TRUE) {
        printMovieHeaderInfo(mvidFilenameCstr);
      }
    }
	} else {
    fprintf(stderr, "%s", USAGE);
    exit(1);
  }
  
  [pool drain];
  return 0;
}

