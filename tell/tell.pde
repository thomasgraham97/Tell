import ddf.minim.*;
import ddf.minim.analysis.*;
import ddf.minim.effects.*;
import ddf.minim.signals.*;
import ddf.minim.spi.*;
import ddf.minim.ugens.*;
import processing.net.*;

/*
INTERNAL STATE
*/

public static final boolean debug = false;
boolean  recording;
boolean  playingRecursion;
boolean  playingDrone;

/*
NETWORKING
*/

Server server;
int transmitCenterFrequency;
float r, g, b;

/*
RECORDING and STORAGE STACK
*/

Minim minim;
AudioInput input;

float   gateMinConsiderThreshold = 0.05;  //Audio level must exceed this amount to consider recording
int     gateMinConsiderFrames = 3;     //Audio level must exceed amount for this amount of frames to begin recording

float   recMinConsiderThreshold = 0.0125;  //Audio level must fall below this amount to consider storing sample
int     recMinConsiderFrames = 15;     //Audio level must fall below amount for this amount of frames to store sample (reduces pop)
int     recMinTime = 500, recMaxTime = 5000;       //Audio sample cannot be outside these bounds
int     recStartTime, recDeltaTime;   //How long since audio started recording?

ArrayList<Float> recActiveRecordingBuffer; //The buffer that recording writes to

MultiChannelBuffer[] storedRecordings;  //A fixed array of stored recordings -- for access in playback
ArrayList<Integer> storedRecordingsAvailableIndices; //Whichever indices are available in the above array
float[] storedRecordingsCenterFrequencies;

int     timesPastThreshold; //Number of consecutive frames that have passed the threshold

FFT fft;
float centerFrequency, centerFrequencyNewValue; 

/*
OUTPUT STACK
*/

AudioOutput output;
Delay recursionDelay;

Sampler     recursionSampler;
MultiChannelBuffer activeRecursionBuffer;

float[] workingRecursionBuffer;
int workingRecursionBufferLastIndex;

Sampler    droneSampler;
MultiChannelBuffer  droneBuffer;
float[] droneBufferAsFloatArray;
float[] workingDroneBuffer;

MoogFilter droneRootMoog, droneThirdMoog, droneFifthMoog;

//Recursion
int activeRecursionLengthInMS, activeRecursionStartTime, activeRecursionPlayTime;
int recursionsPerformed, recursionsToPerform, idealRecursionTimeInMS = 30000;

//Drone
int droneLengthInMS, droneStartTime;
Delay droneDelay;

//Triad layering
MoogFilter rootMoog, thirdMoog, fifthMoog;

void setup()
{
  if ( debug ) { println ("starting setup..."); }
  
  server = new Server (this, 12345);
  
  minim = new Minim (this);
  input = minim.getLineIn();
  output = minim.getLineOut(Minim.STEREO, 1024);
  
  rootMoog = new MoogFilter ( 440, 0, MoogFilter.Type.BP );
  thirdMoog = new MoogFilter ( 554, 0, MoogFilter.Type.BP );
  fifthMoog = new MoogFilter ( 659, 0, MoogFilter.Type.BP );
  
  droneRootMoog = new MoogFilter ( 440, 0, MoogFilter.Type.BP );
  droneThirdMoog = new MoogFilter ( 554, 0, MoogFilter.Type.BP );
  droneFifthMoog = new MoogFilter ( 659, 0, MoogFilter.Type.BP );
  
  fft = new FFT (1024, input.sampleRate() );
  fft.linAverages (30);
  centerFrequency = 5;
  
  recursionDelay = new Delay (0.5, 0.95, true, false);
  recursionDelay.patch (rootMoog); rootMoog.patch (thirdMoog); thirdMoog.patch (fifthMoog);
  fifthMoog.patch(output);
  recursionDelay.patch (output);
  
  droneDelay = new Delay ( 0.25, 0.75, true, false );
  droneDelay.patch ( droneRootMoog ); droneRootMoog.patch ( droneThirdMoog ); droneThirdMoog.patch ( droneFifthMoog );
  droneFifthMoog.patch(output);
  
  size (1024,768);
  
  //Set up stored recordings arrays;
  storedRecordings = new MultiChannelBuffer[5];
  storedRecordingsAvailableIndices = new ArrayList<Integer>();
  recActiveRecordingBuffer = new ArrayList<Float>();
  
 if ( debug ) { println ("adding available recording indices..."); }
 
  for ( int i = 0; i < storedRecordings.length; i++ )
    {  storedRecordingsAvailableIndices.add (i);  }  //Every index is available
  
 if ( debug ) { println ("finished setup."); }   
}

void draw()
{
  float inputMixLevel = input.mix.level();
  fft.forward ( output.mix );
  
  float rDomain = fft.specSize() - ( ( fft.specSize() * 2 ) / 6 ); 
  float bDomain = fft.specSize() / 6;
  float gDomain = ( ( (fft.specSize() * 2) / 6) - (fft.specSize() / 6 ) );

  for ( int index = 0; index < fft.specSize() / 6; index++ )
  {
        b += fft.getBand(index);
  }     b /= bDomain / 8;
 

  for ( int index = fft.specSize() / 6; index < (fft.specSize() * 2) / 6; index++ )
  {
        g += fft.getBand(index);
  }     g /= gDomain / 20;

  for ( int index = ( fft.specSize() * 2 ) / 6; index < fft.specSize(); index++ )
  {
        r += fft.getBand(index);
  }     r /= rDomain / 116;

  
  if ( recording )
  {
    recDeltaTime = millis() - recStartTime;  //Update time since recording started
    
    //Recording level check
    if ( inputMixLevel < recMinConsiderThreshold ) //Check if recording has gone too quiet to continue
    { timesPastThreshold++; }                      //and if so, add to threshold counter
    else
      { timesPastThreshold = 0; }                  //Reset counter if recording is loud enough
    
    //Trigger store recording
    if ( timesPastThreshold > recMinConsiderFrames && recDeltaTime > recMinTime || recDeltaTime > recMaxTime )
    {  //If the recording has been too quiet for too long, and the recording is past the minimum time, OR the recording has gone on too long...
      storeRecording();  //Store it
      
      recDeltaTime = 0; timesPastThreshold = 0;  //Reset the recording time and threshold counter
      recording = false; //And turn off the recording state
      
      if ( debug ) { print ("finished recording; time " + recDeltaTime + "ms\n"); }
    }
    else
    {
      //Recording process
    
      float[] _sampleArray = input.mix.toArray();
    
      for ( int index = 0; index < _sampleArray.length; index++ )
      {      recActiveRecordingBuffer.add ( (Float)_sampleArray [index] );    }
    }
  }
  else
  {
    //Gatekeeping level check
    if ( inputMixLevel > gateMinConsiderThreshold ) //Check if recording is loud enough to consider recording it 
      { timesPastThreshold++; }                     //If it is, add to the threshold counter
    else
      { timesPastThreshold = 0; }                   //Reset the counter if the recording gets too quiet
    
    //Trigger recording state
    if ( timesPastThreshold > gateMinConsiderFrames ) //If the recording has been loud enough for long enough
    { 
      recording = true;         //Turn on the recording state
      recStartTime = millis();  //Set the recording start time
      
      timesPastThreshold = 0;   //Reset the threshold counter
      recActiveRecordingBuffer = new ArrayList<Float>(); //and the active recording buffer
      
      if ( debug ) { print ("started recording.\n"); }
    }
  }
  
  if ( playingRecursion )
  {
    //Check if at end of sample
    if ( millis() - activeRecursionStartTime >= activeRecursionLengthInMS )
    {  
      if ( recursionsPerformed >= recursionsToPerform ) { storeDrone(); playingRecursion = false; playingDrone = true; }
      else { performRecursion(); }
    }
    
    float [] _outputToArray = output.mix.toArray();
   
    for ( int readIndex = 0; readIndex < _outputToArray.length; readIndex++, workingRecursionBufferLastIndex++ )
    {
      if ( workingRecursionBufferLastIndex >= workingRecursionBuffer.length ) { workingRecursionBufferLastIndex = 0; }
      workingRecursionBuffer [workingRecursionBufferLastIndex] = _outputToArray[readIndex];
      
      rootMoog.frequency.setLastValue ( centerFrequency );
      thirdMoog.frequency.setLastValue ( centerFrequency / ( random (0.0, 1.0) > 0.5 ? 0.8 : 0.8333 ) ); //Major or minor — #TODO: enumerate between various chord types
      fifthMoog.frequency.setLastValue ( centerFrequency / ( 2.0 / 3.0 ) );
    }
  }
  
  if ( playingDrone )
  {
    if ( millis() - droneStartTime >= droneLengthInMS )
    {
      performDrone();
    }

    droneRootMoog.frequency.setLastValue ( centerFrequency );
    droneThirdMoog.frequency.setLastValue ( centerFrequency / ( random (0.0, 1.0) > 0.5 ? 0.8 : 0.8333 ) ); //Major or minor — #TODO: enumerate between various chord types
    droneFifthMoog.frequency.setLastValue ( centerFrequency / ( 2.0 / 3.0 ) );
  }
  
  centerFrequency = lerp ( centerFrequency, centerFrequencyNewValue, 0.01 );
  
  /*
  NETWORKING
  */
  
  server.write ( (int)(output.mix.level() * (playingRecursion ? 2000 : 1000 ) ) + " " + (int)(r * 1000) + " " + (int)(g * ( playingDrone ? 2000 : 1000 ) ) + " " + (int)(b * 1000) + "\n" ); 
  
  if ( debug )
    {    print ( ( playingRecursion ? "RECURSION " + recursionsPerformed + "/" + recursionsToPerform + " " + "sample length: " + activeRecursionLengthInMS  + " center frequency: " + centerFrequency + "\n": "" ) + 
                 ( recording ? "REC " + recDeltaTime + "ms\n" : "") +
                 ( playingDrone ? "DRONE BUFFER LENGTH: " + workingDroneBuffer.length + "\n": "" ) +
                 "input mix level: " + inputMixLevel + " | output mix level: " + output.mix.level() + "\n");  
    }
}

void storeRecording()
{
  /*
  ADD TO STORED RECORDING ARRAY — For occasionally patching in unspoiled, unmodified recordings through "left" speaker channel.
  */
  
  int _availIndicesSize = storedRecordingsAvailableIndices.size();  //Get how many available indices there are
  
  Float[] _recActiveRecordingBuffer = recActiveRecordingBuffer.toArray ( new Float [recActiveRecordingBuffer.size()] );
  float[] _recActiveRecordingBufferArray = new float [ _recActiveRecordingBuffer.length ];
  
  for ( int index = 0; index < _recActiveRecordingBufferArray.length; index++ )
    {  _recActiveRecordingBufferArray [ index ] = (float)_recActiveRecordingBuffer [ index ];  }
  
  MultiChannelBuffer _recordingToStore = new MultiChannelBuffer ( _recActiveRecordingBufferArray.length, 1 ); //Convert the active recording buffer to a MultiChannelBuffer
  _recordingToStore.setChannel (0, _recActiveRecordingBufferArray);
  
  //Randomly choose from available indices. If none available, choose any
  if ( _availIndicesSize > 0 )
    { storedRecordings [ storedRecordingsAvailableIndices.get ( floor ( random (0, _availIndicesSize) ) ) ] = _recordingToStore; }
  else { storedRecordings [ floor ( random(0,4) ) ] = _recordingToStore; }
  
  /*
  SET NEW RECURSION BUFFER — For the recording that immediately erupts after user interaction.
  */
  
  activeRecursionBuffer = new MultiChannelBuffer ( _recActiveRecordingBufferArray.length, 1 );  //Blank the active recursion buffer, set it to the length of the new one
  activeRecursionBuffer.setChannel (0, _recActiveRecordingBufferArray);                         //Set the contents of the recursino buffer to the new one
  
  workingRecursionBuffer = new float [ _recActiveRecordingBufferArray.length ];    //Blank the working recursion buffer, set it to the length of the new active buffer
  workingRecursionBufferLastIndex = 0;                                             //Set the recursion write index to 0
  
  /*
  SET NEW RECURSION SAMPLER — Tell the recursion sampler to use the new information.
  */
  
  if ( recursionSampler == null )  {    recursionSampler = new Sampler ( activeRecursionBuffer, input.sampleRate(), 1 );  }
  else 
  { 
    recursionSampler.stop();
    
    recursionSampler.unpatch (recursionDelay);
    recursionSampler.setSample ( activeRecursionBuffer, input.sampleRate() );
  }
  
  activeRecursionLengthInMS = recDeltaTime;  
  
  recursionSampler.patch(output);
  recursionSampler.attack.setLastValue ( min (activeRecursionLengthInMS / 200.0, 0.1) );
  recursionSampler.trigger();
  
  /*
  SET NEW RECURSION STATE — Update the internal state variables surrounding recursion recording and looping
  */
  
 /* centerFrequency = 5; //Fix
  for ( int i = 0; i < 4; i++ )
    { centerFrequency = lerp (centerFrequency, (735 * i), fft.getBand(i) / 1024.0 ); }*/

  recursionSampler.unpatch(output);
  recursionSampler.patch (recursionDelay);
  
  activeRecursionStartTime = millis();
  recursionsPerformed = 0;  recursionsToPerform = (int)(idealRecursionTimeInMS / activeRecursionLengthInMS);
  playingRecursion = true; playingDrone = false;
}

void performRecursion()
{
  recursionSampler.stop();
  
  centerFrequency = random ( 400.0, 1200.0 ); //Makes for strange pitch-jumping and bending
  centerFrequencyNewValue = random ( 400.0, 1200.0 );

  rootMoog.frequency.setLastValue ( centerFrequency );
  thirdMoog.frequency.setLastValue ( centerFrequency / ( random (0.0, 1.0) > 0.5 ? 0.8 : 0.8333 ) ); //Major or minor — #TODO: enumerate between various chord types
  fifthMoog.frequency.setLastValue ( centerFrequency / ( 2.0 / 3.0 ) );
  
  rootMoog.resonance.setLastValue ( min ( recursionsPerformed / (recursionsToPerform * 0.625 ), random (0.35, 0.75) ) );
  thirdMoog.resonance.setLastValue ( min ( recursionsPerformed / (recursionsToPerform * 0.625 ), random (0.35, 0.75) ) );
  fifthMoog.resonance.setLastValue ( min ( recursionsPerformed / (recursionsToPerform * 0.625 ), random (0.35, 0.75) ) );
    
  activeRecursionStartTime = millis();
  
  /*
  SET NEW RECURSION SAMPLER — Tell the recursion sampler to use the new information.
  */
  
  activeRecursionBuffer = new MultiChannelBuffer ( workingRecursionBuffer.length, 1 ); //Test: fix double pitch issue?
  activeRecursionBuffer.setChannel (0, workingRecursionBuffer);
  recursionSampler.trigger();
  
  workingRecursionBufferLastIndex = 0;

  if ( debug ) { print ("performing recursion at " + activeRecursionStartTime + "ms."); }
  
  recursionsPerformed++;
}

void performDrone()
{
  droneStartTime = millis();

  centerFrequencyNewValue = random ( 400.0, 1200.0 );

  droneRootMoog.frequency.setLastValue ( centerFrequency );
  droneThirdMoog.frequency.setLastValue ( centerFrequency / ( random (0.0, 1.0) > 0.5 ? 0.8 : 0.8333 ) ); //Major or minor — #TODO: enumerate between various chord types
  droneFifthMoog.frequency.setLastValue ( centerFrequency / ( 2.0 / 3.0 ) );
  
  droneRootMoog.resonance.setLastValue ( random (0.35, 0.5) );
  droneThirdMoog.resonance.setLastValue ( random (0.35, 0.5) );
  droneFifthMoog.resonance.setLastValue ( random (0.35, 0.5) );
  
  droneSampler.trigger(); //<>//
}

void storeDrone() //Transfer contents of working recursion buffer to drone buffer
{
  if ( droneBufferAsFloatArray == null ) { droneBufferAsFloatArray = new float[1]; }
  
  workingDroneBuffer = new float [ max ( droneBufferAsFloatArray.length, workingRecursionBuffer.length ) ];
  
  for ( int writeIndex = 0, readRecursionIndex = 0, readDroneIndex = 0; writeIndex < workingDroneBuffer.length; writeIndex++, readRecursionIndex++, readDroneIndex++ )
  {
    if ( readRecursionIndex >= workingRecursionBuffer.length ) { readRecursionIndex = 0; }
    if ( readDroneIndex >= droneBufferAsFloatArray.length ) { readDroneIndex = 0; } //Loop if at end of buffer
    
    workingDroneBuffer [writeIndex] = lerp (lerp ( workingRecursionBuffer[readRecursionIndex], droneBufferAsFloatArray[readDroneIndex], 0.66 ), 0.0, 0.25);
  }

  droneBufferAsFloatArray = workingDroneBuffer;
    
  droneBuffer = new MultiChannelBuffer ( droneBufferAsFloatArray.length, 1 );
  droneBuffer.setChannel ( 0, workingDroneBuffer );
  
  if ( droneSampler == null ) { droneSampler = new Sampler ( droneBuffer, input.sampleRate(), 1 ); }
  else 
  { 
    droneSampler.stop();   
    droneSampler.unpatch (droneDelay);
    droneSampler.setSample ( droneBuffer, input.sampleRate() );
  }
  
  droneSampler.patch(droneDelay);
  droneSampler.trigger();
  
  droneLengthInMS = max ( droneLengthInMS, activeRecursionLengthInMS );
  droneStartTime = millis();
}