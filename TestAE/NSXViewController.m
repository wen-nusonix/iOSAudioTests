//
//  NSXViewController.m
//  TestAE
//
//  Created by Chih-Po Wen on 4/4/13.
//  Copyright (c) 2013 Chih-Po Wen. All rights reserved.
//

#import "NSXViewController.h"
#import "TheAmazingAudioEngine.h"
#import "AEExpanderFilter.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/AudioFile.h>
#import <AudioToolbox/ExtendedAudioFile.h>
#import "AERecorder.h"


@interface NSXViewController () {
    AEAudioController *audioController;
    AEAudioFilePlayer *voicePlayer;
    AEAudioFilePlayer *arrangementPlayer;
    AEAudioUnitFilter *reverb;
    AEExpanderFilter *expander;
    AERecorder *recorder;
    AERecorder *aacRecorder;
    
    AEBlockFilter *paddingFilter;
    AEChannelGroupRef topChannelGroup;
    AEChannelGroupRef voiceChannelGroup;
    AEChannelGroupRef arrangementChannelGroup;
    AEBlockAudioReceiver *arrangementChannelGroupReceiver;
    int framesSinceLastAdjust;
    int framesSkipped;
    int framesPadded;
}


@end


@implementation NSXViewController


- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
    
    [self startDemo];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)configureVoice:(int)framesToPad inputFile:(NSString*)inputFile
{
  
    // Create the voice player 
    
    // NSURL *vmedia = [[NSBundle mainBundle] URLForResource:@"voice2-spx" withExtension:@"wav"];
    // NSURL *vmedia = [[NSBundle mainBundle] URLForResource:@"voice1" withExtension:@"wav"];
//    NSURL *vmedia = [[NSBundle mainBundle] URLForResource:@"voice3" withExtension:@"wav"];
    
    NSURL *vmedia = [NSURL fileURLWithPath:inputFile];

    
    voicePlayer = [AEAudioFilePlayer audioFilePlayerWithURL:vmedia audioController:audioController  error:NULL];
    voicePlayer.volume = 2;
    voicePlayer.channelIsMuted = FALSE;
    voicePlayer.loop = FALSE;
    
    // Create the voice player channel group and add the voice player to it
    
    voiceChannelGroup = [audioController createChannelGroupWithinChannelGroup:topChannelGroup];
    [audioController addChannels:[NSArray arrayWithObjects:voicePlayer, nil] toChannelGroup:voiceChannelGroup];

    
    // create the delay block filter to the voice channel group
    
    framesPadded = 0;
    paddingFilter = [AEBlockFilter filterWithBlock:^(AEAudioControllerFilterProducer producer, void *producerToken, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
        
        
        if (framesPadded > framesToPad) {
            // pad more silence to align ending
            OSStatus status = producer(producerToken, audio, &frames);
            if ( status != noErr ) return;
        } else {
            framesPadded += frames;
        }
        
    }];
    [audioController addFilter:paddingFilter toChannelGroup:voiceChannelGroup];
    
    
    // Add a noise reduction filter to the voice channel group
    
    expander = [[AEExpanderFilter alloc] initWithAudioController:audioController];
    [expander assignPreset:AEExpanderFilterPresetSmooth];
    [audioController addFilter:expander toChannelGroup:voiceChannelGroup];
    
    // Add reverb filter to voice channel group
    
    reverb = [[AEAudioUnitFilter alloc] initWithComponentDescription:AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Effect, kAudioUnitSubType_Reverb2) audioController:audioController error:NULL];
    AudioUnitSetParameter(reverb.audioUnit, kReverb2Param_DryWetMix, kAudioUnitScope_Global, 0, 50.f, 0);
    [audioController addFilter:reverb toChannelGroup:voiceChannelGroup];

}

- (void)configureArrangement
{
    
    // create the arrangement player (from a remote URL)
    
    NSURL *media = [[NSBundle mainBundle] URLForResource:@"arrangement1" withExtension:@"wav"];
    
    arrangementPlayer = [AEAudioFilePlayer audioFilePlayerWithURL:media audioController:audioController  error:NULL];
    
    arrangementPlayer.volume = 1;
    arrangementPlayer.channelIsMuted = FALSE;
    arrangementPlayer.loop = FALSE;
    
    // create the arrangement channel group and add the arrangement player
    
    arrangementChannelGroup = [audioController createChannelGroupWithinChannelGroup:topChannelGroup];
    [audioController addChannels:[NSArray arrayWithObjects:arrangementPlayer, nil] toChannelGroup:arrangementChannelGroup];
    
}

- (void)configureVolumeEqualizer
{

    //
    // sets up the receiver, triggered by arrangment, but sample power level for both voice and arrangement. the volume adjustment is dampened at + or - 10% per 10000 frames. 
    //

    framesSinceLastAdjust = 0;
    arrangementChannelGroupReceiver = [AEBlockAudioReceiver audioReceiverWithBlock:^(void *source, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
        
        if (framesSinceLastAdjust < 0) {
            // done with adjustments
            return;
        }
        
        const int FRAMES_PER_ADJUST = 10000;
        framesSinceLastAdjust += frames;
        if (framesSinceLastAdjust > FRAMES_PER_ADJUST) {
            framesSinceLastAdjust = 0;
        } else {
            // not yet
            return;
        }
        
        if (![voicePlayer channelIsPlaying] && arrangementPlayer.volume < 1) {
            [arrangementPlayer setVolume:arrangementPlayer.volume * 1.1];
            if (arrangementPlayer.volume >= 1) {
                //framesSinceLastAdjust = -1;
            }
            // NSLog(@"Lower arrangement at %lf to volume: %f", time->mSampleTime, arrangementPlayer.volume);
            return;
        }
        
        // poll the volume on both channels so that we can equalize (gradually)
        
        Float32 voiceAverage, voicePeak, arrangementAverage, arrangementPeak;
        [audioController averagePowerLevel:&voiceAverage peakHoldLevel:&voicePeak forGroup:voiceChannelGroup];
        [audioController averagePowerLevel:&arrangementAverage peakHoldLevel:&arrangementPeak forGroup:arrangementChannelGroup];
        
        // both are negative number
        double ratio =  arrangementAverage / voiceAverage;
        if (ratio < 0.75) {
            if (arrangementPlayer.volume > 0.50) {
                [arrangementPlayer setVolume:arrangementPlayer.volume * 0.9];
                // NSLog(@"Lower arrangement at %lf to volume: %f", time->mSampleTime, arrangementPlayer.volume);
            }
        } else if (ratio > 1.25) {
            if (arrangementPlayer.volume < 1) {
                [arrangementPlayer setVolume:arrangementPlayer.volume * 1.1];
                // NSLog(@"Increase arrangement at %lf to volume: %f", time->mSampleTime, arrangementPlayer.volume);
            }
        }
    }];
    
    [audioController addOutputReceiver:arrangementChannelGroupReceiver forChannelGroup:arrangementChannelGroup];
    
}

- (void)startDemo
{
    
    if (audioController == Nil) {
    
        // Create an instance of the audio controller, set it up and start it running
        audioController = [[AEAudioController alloc] initWithAudioDescription:[AEAudioController nonInterleaved16BitStereoAudioDescription] inputEnabled:YES];
        audioController.preferredBufferDuration = 0.005;
    
        [audioController start:NULL];
    } 
}

- (void)resetAudio
{
    // TBD -- how is one supposed to do this properly?
    if (topChannelGroup != Nil) {
        [audioController stop];
        [audioController removeChannelGroup:topChannelGroup];
        [audioController start:NULL];
        topChannelGroup = Nil;
    }
}

- (void)constructAE:(id)sender
{
    [self resetAudio];
    
    NSString *tmpId = [[NSProcessInfo processInfo] globallyUniqueString] ;
    NSString *tmpFile = [self getFile:[NSString stringWithFormat:@"stmp_%@.wav", tmpId]];

    // NSURL *inURL = [[NSBundle mainBundle] URLForResource:@"voice2-spx" withExtension:@"wav"];
    // NSURL *inURL = [[NSBundle mainBundle] URLForResource:@"voice1" withExtension:@"wav"];
    // NSURL *inURL = [[NSBundle mainBundle] URLForResource:@"voice4" withExtension:@"wav"];

    //NSURL *inURL = [NSURL fileURLWithPath:[self getFile:@"recorded.wav"]];
    NSURL *inURL = [NSURL fileURLWithPath:[self getFile:@"recorded.caf"]];

    NSURL *outURL = [NSURL fileURLWithPath:tmpFile];

    float voiceDuration = [self trimSilenceAndScaleWav:inURL outURL:outURL scaleVolume:TRUE];
    
    double PADDING_SECONDS = 18 - voiceDuration;
    

    
    int paddingFrames = AEConvertSecondsToFrames(audioController, PADDING_SECONDS);
    NSLog(@"Frames to be padded = %d ", paddingFrames);
    
    // create top level channel group
    topChannelGroup = [audioController createChannelGroup];
    
    [self configureVoice:paddingFrames inputFile:tmpFile];
    
    [self configureArrangement];
    
    [self configureVolumeEqualizer];
    
}

- (float)trimSilenceAndScaleWav:(NSURL*)inURL outURL:(NSURL*)outURL scaleVolume:(BOOL)scale
{
#define SILENCE_THRESHOLD       200
#define SILENCE_MARGIN_SECS     0.5
#define SEGMENT_SIZE_SECS       (SILENCE_MARGIN_SECS / 2)
    OSStatus							err = noErr;
    ExtAudioFileRef						inputAudioFileRef = NULL;
    AudioStreamBasicDescription			inputFileFormat;
    ExtAudioFileRef						outputAudioFileRef = NULL;
    AudioStreamBasicDescription			outputFileFormat;
    UInt32								thePropertySize = sizeof(inputFileFormat);
	UInt8 *buffer = NULL;
    
    err = ExtAudioFileOpenURL((__bridge CFURLRef)(inURL), &inputAudioFileRef);
    
    if (err) { NSLog(@"Failed to open file"); }
    
    bzero(&inputFileFormat, sizeof(inputFileFormat));
    err = ExtAudioFileGetProperty(inputAudioFileRef, kExtAudioFileProperty_FileDataFormat,
								  &thePropertySize, &inputFileFormat);
    if (err) { NSLog(@"Failed to read input format"); }
    
    // NSLog(@"%d %d", kAudioFormatFlagIsSignedInteger, kAudioFormatFlagIsPacked);
    
    int BUFFER_SIZE = (int)(SEGMENT_SIZE_SECS * inputFileFormat.mSampleRate);
    
    buffer = malloc(BUFFER_SIZE);
    AudioBufferList conversionBuffer;
	conversionBuffer.mNumberBuffers = 1;
	conversionBuffer.mBuffers[0].mNumberChannels = inputFileFormat.mChannelsPerFrame;
	conversionBuffer.mBuffers[0].mData = buffer;
	conversionBuffer.mBuffers[0].mDataByteSize = BUFFER_SIZE;
    
    UInt32 totalFrames = 0;
    UInt32 firstFrame = 0;
    UInt32 lastFrame = 0;
    SInt32 peak = 0;
	while (TRUE) {
		conversionBuffer.mBuffers[0].mDataByteSize = BUFFER_SIZE;
        
		UInt32 frameCount = INT_MAX;
        
		if (inputFileFormat.mBytesPerFrame > 0) {
			frameCount = (conversionBuffer.mBuffers[0].mDataByteSize / inputFileFormat.mBytesPerFrame);
		}
        
		// Read a chunk of input
        
		err = ExtAudioFileRead(inputAudioFileRef, &frameCount, &conversionBuffer);
		if (err) {
            NSLog(@"failed to read frames");
        }
        
		// If no frames were returned, conversion is finished
        
		if (frameCount == 0)
			break;
        
		// examine buffer (assuming 2-byte signed int per frame)
        
        SInt16 *frames = (SInt16*) buffer;
        UInt64 bufferSum = 0;
        for (int i = 0 ; i < frameCount; ++i) {
            SInt32 frame = frames[i];
            SInt32 amp = frame > 0 ? frame : -1 * frame;
            bufferSum += amp;
            peak = (peak < amp ? amp : peak);
        }
        
        // declare frame as silent if the avg is below threshold
        
        SInt32 avg = bufferSum / frameCount;
        if (avg < SILENCE_THRESHOLD) {
            // silence
            // NSLog(@"Silence: %ld ", totalFrames);
        } else {
            lastFrame = totalFrames + frameCount;
            if (firstFrame == 0) {
                firstFrame = totalFrames;
            }
        }
        
        totalFrames += frameCount;
    }
   
    float durationSecs = ((float) totalFrames) / inputFileFormat.mSampleRate;
    float startSec = ((float)firstFrame) / inputFileFormat.mSampleRate - SILENCE_MARGIN_SECS;
    float endSec = ((float)lastFrame) / inputFileFormat.mSampleRate + SILENCE_MARGIN_SECS;
    float ampMultiplier = 32767.0 / peak;
    
    if (startSec < 0) {
        startSec = 0;
    }
    if (endSec > durationSecs) {
        endSec = durationSecs;
    }
    
    NSLog(@"%f - %f sec, %lf secs, peak %ld", startSec, endSec, durationSecs, peak);
    
    ExtAudioFileDispose(inputAudioFileRef);
    
    // copy the calculated voice segment to a new output file
    
    err = ExtAudioFileOpenURL((__bridge CFURLRef)(inURL), &inputAudioFileRef);
    
    if (err) { NSLog(@"Failed to re-open file"); }
    
    memcpy( &outputFileFormat, &inputFileFormat, sizeof(inputFileFormat));
    
    UInt32 flags = kAudioFileFlags_EraseFile;
    err = ExtAudioFileCreateWithURL((__bridge CFURLRef)outURL, kAudioFileWAVEType, &outputFileFormat,
									NULL, flags, &outputAudioFileRef);
    
    if (err) { NSLog(@"Failed to create file"); }
    
    UInt32 startCopy = startSec * inputFileFormat.mSampleRate;
    UInt32 endCopy = endSec * inputFileFormat.mSampleRate;
    UInt32 currFrame = 0;
    buffer = malloc(BUFFER_SIZE);
    conversionBuffer.mNumberBuffers = 1;
	conversionBuffer.mBuffers[0].mNumberChannels = inputFileFormat.mChannelsPerFrame;
	conversionBuffer.mBuffers[0].mData = buffer;
	conversionBuffer.mBuffers[0].mDataByteSize = BUFFER_SIZE;
    while (TRUE) {
		conversionBuffer.mBuffers[0].mDataByteSize = BUFFER_SIZE;
        
		UInt32 frameCount = INT_MAX;
        
		if (inputFileFormat.mBytesPerFrame > 0) {
			frameCount = (conversionBuffer.mBuffers[0].mDataByteSize / inputFileFormat.mBytesPerFrame);
		}
        
		// Read a chunk of input
        
		err = ExtAudioFileRead(inputAudioFileRef, &frameCount, &conversionBuffer);
		if (err) {
            NSLog(@"failed to read frames");
        }
        
		// If no frames were returned, conversion is finished
        
		if (frameCount == 0)
			break;

        if (currFrame + frameCount >= startCopy) {
            // scale if so specified
            if (scale && ampMultiplier > 1) {
                SInt16 *frames = (SInt16*) buffer;
                
                // TBD -- use the Accelerator framework for this
                for (int i = 0; i < frameCount; ++ i) {
                    SInt16 frame = ((float)frames[i]) * ampMultiplier;
                    frames[i] = frame;
                }
            }
            err = ExtAudioFileWrite(outputAudioFileRef, frameCount, &conversionBuffer);
        } else if (currFrame > endCopy) {
            break;
        }
        
        currFrame += frameCount;
    }
    
    ExtAudioFileDispose(inputAudioFileRef);
    ExtAudioFileDispose(outputAudioFileRef);
    
    return endSec - startSec;
}

- (void)startRecording:(id)sender
{
    [self resetAudio];
    
    // wav recorder
    
    NSString *outputFile = [self getFile:@"recorded.wav"];
    NSLog(@"Writing recording to file %@", outputFile);
    NSError *error = NULL;
    recorder = [[AERecorder alloc] initWithAudioController:audioController];
    if (![recorder beginRecordingToFileAtPath:outputFile fileType:kAudioFileWAVEType error:&error]) {
        NSLog(@"Failed to begin recording");
    }
    [audioController addInputReceiver:recorder];
    
    // aac recorder
    
    outputFile = [self getFile:@"recorded.caf"];
    NSLog(@"Writing recording to file %@", outputFile);
    error = NULL;
    aacRecorder = [[AERecorder alloc] initWithAudioController:audioController];
    if (![aacRecorder beginRecordingToFileAtPath:outputFile fileType:kAudioFileCAFType error:&error]) {
        NSLog(@"Failed to begin recording");
    }
    [audioController addInputReceiver:aacRecorder];
    
}

- (void)stopRecording:(id)sender
{
    [self resetAudio];
    
    [recorder finishRecording];
    [audioController removeInputReceiver:recorder];
    
    [aacRecorder finishRecording];
    [audioController removeInputReceiver:aacRecorder];

    
}

- (NSString*) getFile:(NSString*)name
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *file = [documentsDirectory stringByAppendingPathComponent:name];
    return file;
}

@end
