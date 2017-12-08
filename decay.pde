import ddf.minim.*;
import ddf.minim.ugens.*;
import ddf.minim.analysis.*;

/* QUICK SUMMARY:
|   This is a sketch for an interactive video installation. It uses audio input to manipulate a particle system, and applies quasi-generation loss
|   to that signal. The audio side of things works like this:
|      PART A: Recording
|      1) Listen in if the input audio signal exceeds a given threshold. If it does, and we're not recording, start recording.
|      2) If we're recording signal, add that to a buffer of arbitrary length.
|      PART B: Ending recording
|      1) Listen in if the input audio signal falls below a given threshold. If it does, and we're recording, stop recording.
|      2) If we've stopped recording, pass the recorded signal to a Sample playback object hooked to several filters, and loop.
|      PART C: Playback
|      1) If we're playing audio, record what's coming out of the output to a special buffer. 
          This should sound different from what's in the Sample object's buffer, because low pass and delay effects have been applied. 
|      2) If we've reached the end of playback, pass what the special buffer recorded to the Sample object.
|      3) Repeat steps 1-2. 
|   And the visual side of things works like this:
|      PART A: Frequency to colour
|      1) If the amount of output signal exceeds a given threshold, translate the total amount of signal within certain ranges of audio frequency 
|         to the intensity of red, blue and green in a stored variable.
|      2) Add particles to a particle management system, setting the rate of spread according to intensity of output signal, 
|         and colouring them according to what was landed on in step 1.
|      PART B: Sprite display
|      1) Cycle through every sprite registered in particle management, displaying them according to their position, rotation and colour.
|         Shift the colours slightly using various sinusoidal waves.
|      2) Change each sprite's location and rotation values according to their velocity and rotation velocity values.
*/

/********|
| TUNING |
|********/

float recordStartThreshold = 0.05, recordEndThreshold = 0.01;

/******************
| AUDIO VARIABLES |
******************/

Minim minim;

//Input
AudioInput input; //The audio input stream.

int recordStartTime, minRecordTime = 250, maxRecordTime = 10000; //recordStartTime: When did we start recording (in ms)? | maxRecordTime: What's the longest a recording can be? (prevents memory hogging)
boolean recording;                                               //minRecordTime: What's the shortest a sample can be? (prevents pops) | recording: Is the sketch recording right now?
ArrayList<Float> recordBuffer;                                   //recordBuffer: Arbitrarily-sized array, contains the levels from the audio input stream 

//Recursion

float[] recursionBuffer; int recursionPreviousFrame;  //recursionBuffer: Size based on recordBuffer. Records and holds the output audio to be played and iterated over | recursionPreviousFrame: Last index recorded 
MultiChannelBuffer sampleBuffer;                      //sampleBuffer: The actual buffer that gets played. Set as MultiChannelBuffer to play nice with Minim's Sampler class.

//Output and effects
AudioOutput output;          //The output device.
Sampler sample;              //The playback device. Used instead of AudioSampler to hook into uGens.
   
Delay delay;                //The delay effect. Chief filter responsible for garbling the input over time.
MoogFilter moog;            //High pass filter. Removes the lowest frequencies, which tend to dominate over time.

//Playback 
int playbackMs; float playbackSampleLength;  //playbackMs: The last time the playback sample was triggered, in milliseconds. | playbackSampleLength: Length of the audio sample, in milliseconds.
boolean playing;                             //playing: Is the sketch playing audio right now?

//Analysis
FFT fft;   //Fast Fourier Transform class. Analyses the sample's frequencies.

/*********************
| GRAPHICS VARIABLES |
*********************/

PGraphics pg;      //The object for our draw call. Visuals get consolidated here to save processing and memory overhead.
PImage    caustic; //Image for our particle system
particleSystem causticsSystem;  //An ad hoc particle system to manage the water caustic sprites
  
float sineCounter, sineTick = PI;  //Sine gets used shimmering effect

float r = 0, g = 0, b = 0;  //Buffer variables for each sprite's colour

void setup()
{
  fullScreen(P2D); //Set P2D renderer for better performance
  frameRate(60);   //Set a fixed framerate
  
  /**************
  | AUDIO SETUP |
  **************/
  
  minim = new Minim(this);
  input = minim.getLineIn();
  output = minim.getLineOut(Minim.STEREO, 4096);  //The sample size is a power of 2 so it plays nice with the FFT object
  
  delay = new Delay(0.25, 0.95, true, false);  //Quarter second delay, 95% gain retention, feedback enabled (end of loop bleeds into start), output audio passing not
  moog = new MoogFilter (30, 1.0);  //Filtering out the lowest frequencies
  moog.type = MoogFilter.Type.HP;   //as a health and safety measure
  
  fft = new FFT( 4096, output.sampleRate() );  //Sample size and rate matches 'output'
  
  input.enableMonitoring();  //Repeats what you say back, mostly a testing feature of questionable aesthetic significance. May be removed at later time
  
  /*****************
  | GRAPHICS SETUP |
  *****************/
  
  pg = createGraphics (width, height, P2D); //Fill the screen, start a renderer
  pg.noSmooth(); //Improves performance a little
  pg.beginDraw();
    pg.background(0);  //Start on a black background
    pg.fill(0,150);    //Fade to black, alpha manages speed of subtraction
    pg.tint(255,10);    //Make images transparent, alpha manages speed of addition
    pg.imageMode(CENTER); //Makes life easier when placing sprites, may be swapped for 'CORNERS' to facilitate warping
  pg.endDraw();
  
  caustic = loadImage("caustic.jpg");
  causticsSystem = new particleSystem();
}

void draw()
{  
  /********
  | AUDIO |
  ********/
  
  if ( millis() % 4 == 0 )   //LEVEL CHECKING: Every four levels see if microphone input is above or below
  {                          //starting and stopping thresholds
    if (!recording && input.mix.level() >= recordStartThreshold )
    {
      recordBuffer = new ArrayList<Float>();        //Fresh new ArrayList
      recordStartTime = millis(); recording = true; //Reset clock and switch to recording state
    }
    
    else if ( recording && input.mix.level() <= recordEndThreshold && millis() > recordStartTime + minRecordTime )
    {  stopRecording();  }  // ^ If we're below the end threshold and we're past the minimum time needed to make a good sample
  }
  
  if ( playing && millis() > playbackMs + playbackSampleLength )
  {    loopRecording();  }  // ^ If we're at the end of the recording, start from the beginning
  
  else if ( playing ) //While playing, record what's coming out of the output. The resulting recording in recursionBuffer will
  {                   //be used as the next round of output
    recursionBuffer[recursionPreviousFrame] = output.mix.level();  //Grab what's happening with the output this frame
    recursionPreviousFrame++;                                      //Advance one index
  }
  
  if ( recording ) { record(); }
  
  /***********
  | GRAPHICS |
  ***********/
  
   pg.beginDraw();
        //Swtich to BLEND mode to fade out old image, then back to ADD mode to save performance (uses a much simpler formula, notable performance gains)
        pg.blendMode(BLEND); pg.rect(0,0,width,height);    pg.blendMode(ADD);
        
        //If the total amount of noise coming out of the speakers exceeds a given amount (hardcoded now, should really be a variable)
        if ( input.mix.level() + output.mix.level() > 0.125 ) 
        {
            fft.forward( output.mix );  //Perform a forward Fourier transform
            
            //DOMAINS: Each colour corresponds to a range of frequencies. The question is, how large is that range?
            //We're going to accumulate the signals in that range, and so to make the end result proportionate,
            //we need to divide that by the size of the area of collection. This is what this part does.
            //These can be indepedently resized for better configuration. In this case, they're all the same.
            float bDomain = fft.specSize() / 6;                                       //Note that we're only using the
            float gDomain = ( ( (fft.specSize() * 2) / 6) - (fft.specSize() / 6 ) );  //lowest 2/3 of the frequency range.
            float rDomain = fft.specSize() - ( ( fft.specSize() * 2 ) / 6 );          //This is a curiosity of my laptop's mic,
                                                                                      //and would be subject to change in any further iteration
                                                                                      
            //Grabbing the total frequency in each signal range. Works for now but can be made more efficient
            for ( int index = 0; index < fft.specSize() / 6; index++ )
            {     b += fft.getBand(index);     }     b /= bDomain / 8; //Ad hoc fudging of domain size. Makes for more equal 
                                                                       //expression of colours
            for ( int index = fft.specSize() / 6; index < (fft.specSize() * 2) / 6; index++ )
            {     g += fft.getBand(index);     }     g /= gDomain / 32;  //Green gets a nice boost over blue, bc. blue gets a lot of signal

            for ( int index = ( fft.specSize() * 2 ) / 6; index < fft.specSize(); index++ )
            {     r += fft.getBand(index);     }     r /= rDomain / 116; //Red need a huge boost -- would be better to give it a larger domain

            causticsSystem.addParticles( frameRate > 24 ? 8:4, (input.mix.level() + output.mix.level() * 16), r, g, b );  //Add more sprites!
        }  //If the frame rate is getting low avoid spamming more sprites, set the speed of spread according to intensity of output signal, pass colours
        
        causticsSystem.update( (millis() % 2 == 0) ? true : false ); //Update the water caustics, cull out-of-frame objects every two milliseconds
        
        //DISPLAYING SPRITES
        for ( int index = 0; index < causticsSystem.size; index++ )  //Cycle through every particle in the particle system
        {
          particle activeParticle = causticsSystem.get(index);       //Storing the active particle chops things down to one get() call, saves overhead
          pg.tint                                                                       //Tint the forecoming image according to its stored colour values,
          (                                                                             //and mess with those slightly using clamped sinusoidal waves.
            min ( max ( sin ( activeParticle.t ), 0.75) * activeParticle.r, 255),       //Provide a ceiling of 255 for each colour.
            min ( max ( cos ( activeParticle.t ), 0.75) * activeParticle.g, 255), 
            min ( max ( tan ( activeParticle.t ), 0.75) * activeParticle.b, 255),
            max ( sin ( activeParticle.t) * 30, 0.75 )                                  //Same for transparency, with an unclamped max of 30
          ); //The tint ranges above should be 0-255 for R,G,B and 0.75-30 for A.
          
           pg.pushMatrix(); //Store what transform values we've got going on right now (should be at default values)
             pg.translate ( activeParticle.x, activeParticle.y); pg.rotate (activeParticle.a); pg.translate ( -activeParticle.x, -activeParticle.y);
               //^ Move the transform values to this sprite's location, rotate according to the sprite's given angle, move back to default (some funny business, needs work)
             pg.image(caustic, activeParticle.x, activeParticle.y, activeParticle.s, activeParticle.s ); //Finally, display the sprite with colour + rotation
           pg.popMatrix(); //Pop back to default values as a redundancy for the second translate call
        }
        if (millis() % 2 == 0) { causticsSystem.clean(); } //Cull out-of-frame objects every two milliseconds
  pg.endDraw();
  image(pg,0,0); //Display everything that just happened above
  
  //Secret diagnostic features
  println ("VISUALS | Frame rate: " + frameRate + " | Particles on display: " + causticsSystem.size);
  println ("AUDIO | Input mix level: " + input.mix.level() + " | RECORDING: " + recording );
}

/******************
| RECORD FUNCTION |
******************/
void record()
{
  if ( millis() <= recordStartTime + maxRecordTime )              //If we haven't hit the max recording time,
  {                                                               //get what's happening in the input signal mix
    float[] _sampleArray = input.mix.toArray();                   //as an array, cycle through that array, and add each entry
    for ( int index = 0; index < _sampleArray.length; index++ )   //individually to our recordBuffer ArrayList. 
    {                                                             //(This isn't efficient, but setting recordBuffer as a
      recordBuffer.add((Float)_sampleArray[index]);               //float array made for a lot of dead air with short samples
    }
  }
  else { stopRecording(); }
      //^ If we're past the maximum recording time, stop recording 
}

/**************************
| STOP RECORDING FUNCTION |
**************************/
void stopRecording()
{
  recording = false;  //Let the rest of the sketch know 
  playbackSampleLength = (float)(recordBuffer.size() / input.sampleRate() ) * 1000;  //Record the sample's length in milliseconds,
  recursionPreviousFrame = 0;                                                        //reset the counter for the recursion buffer
  
  //Converting recordBuffer from an ArrayList to a float array (takes more mental gymnastics than one might think)
  Float[] _recordBuffer = recordBuffer.toArray(new Float[recordBuffer.size()]);  //There's float and then there's Float -- ArrayList can only convert to the latter
  float[] _recordBufferAsArray = new float[_recordBuffer.length];                //But Float[] doesn't play nice with the MultiChannelBuffer class, nor does it convert
    for ( int index = 0; index < _recordBufferAsArray.length; index++ )          //to float[], so we have to cycle through each Float index and convert it to a float index
    {   _recordBufferAsArray[index] = (float)_recordBuffer[index];    }          //in a float[] array. The latter array is what gets passed down.
    
  recursionBuffer = _recordBufferAsArray;                                        //Set the recusion buffer to the result of the previous section
  loopRecording();                                                               //Play the recording
  
  //Secret debugging features
  println ("RECORDING | Length in ms: " + playbackSampleLength + " | Record buffer length: " + _recordBufferAsArray.length);
}

/**************************
| LOOP RECORDING FUNCTION |
**************************/
void loopRecording()
{
  sampleBuffer = new MultiChannelBuffer ( recursionBuffer.length, 2 );                              //Make a MultiChannel buffer out of the recursion buffer, so it can be fed
  sampleBuffer.setChannel (0, recursionBuffer ); sampleBuffer.setChannel (1, recursionBuffer );     //into the sampler
  
  if ( sample != null )  //If we've already made a Sampler, stop it, unplug it from everything and give it a new MultiChannelBuffer to work with
    {    sample.stop(); sample.unpatch(delay); delay.unpatch(moog); moog.unpatch(output); sample.setSample ( sampleBuffer, input.sampleRate() );  }
  else { sample = new Sampler ( sampleBuffer, input.sampleRate(), 1 ); }  //Otherwise, make a new Sampler and give the MultiChannelBuffer we just made
  
  sample.patch(delay).patch(moog).patch(output); //Hook it up to both our filters
  sample.trigger();                              //and play it!
  playbackMs = millis(); playing = true;         //Set the playback starting time to now, and tell the rest of the system that sound is playing
}

/******************
| PARTICLE SYSTEM |
******************/
class particleSystem
{
  ArrayList<particle> childParticles = new ArrayList<particle>();  //An ArrayList for the particles this particle system will manage
  public int size;                                                 //The size of said ArrayList (reduces size() calls, saves overhead)
  
  //ADDING PARTICLES: Takes on how many to add, the rate at which these particles spread, and their colour
  public void addParticles(int particlesToAdd, float spreadRate, float r, float g, float b) //Giving each particle its own colour
  {                                                                                         //allows for a nice shimmering effect
    for ( int index = 0; index < particlesToAdd; index++ )        //For every particle requested to add, calculate:
    {
      particle newParticle = new particle
      (
        width / 2, height / 2,                                    //Position
        random(-spreadRate * frameRate,spreadRate * frameRate),   //Velocity
        random(-spreadRate * frameRate,spreadRate * frameRate), 
        random(-spreadRate,spreadRate),                           //Spread rate
        random(0, TWO_PI),                                        //Angle (anywhere from 0-360 degrees)
        random(-QUARTER_PI / 16, QUARTER_PI / 16),                //Angle spin rate (anywhere from -1/64pi to 1/64pi a frame, keeps it from going crazy)
        random(0, HALF_PI),                                       //Transparency, stored as a point on a sine wave. Anywhere from invisible (0) to sort of visible (1/2pi)
        lerp (r, 255, 0.5), lerp (pow (g, 1.1), 255, 0.5), lerp (b, 255, 0.5) //Colours are pulled towards 255 to reduce vividness of colour (too much looks wrong somehow)
      );
      childParticles.add(newParticle);  //Register this new particle in the list
    }
    size = childParticles.size();  //Once we've added all of our new particles, update the size variable
  }
  
  //CLEAN: Removes particles off screen and enforces a cap on how many there can be (prevents slowdown)
  public void clean()
  {
    for ( int index = 0; index < size; index ++ )
    {
      particle activeParticle = childParticles.get(index);
      
      if ( activeParticle.x > width || activeParticle.x < 0 || activeParticle.y > height || activeParticle.y < 0 )
      { //^ If this particle is out of bounds...
        childParticles.remove(index);  //Remove it
        childParticles.trimToSize();   //Trim the ArrayList to length
        size--;                        //Update the size variable
      }
      
      if ( size > 600 && Math.random() > 0.5 ) //If we're above 600 particles, (around the point my machine drops below 30fps), and by 50/50 odds...
          { childParticles.remove(index); childParticles.trimToSize(); size--; }  //Remove this particle, trim the ArrayList, update the size variable
    }  
    size = childParticles.size(); //Once we're not cycling through everything, confirm the size variable
  }
  
  //UPDATE: Changes position, angle, and point on sinusoidal values
  public void update(boolean clean)
  {
    for ( int index = 0; index < size; index ++ )
    {
      particle activeParticle = childParticles.get(index);
      
      activeParticle.x += activeParticle.vX / frameRate; activeParticle.y += activeParticle.vY / frameRate;  //Move position, sensitive to frame rate
      activeParticle.s += (max ( abs(activeParticle.vX), abs(activeParticle.vY) ) * 1.25) / frameRate;       //Spread, sensitive to framerate and position
      activeParticle.a += activeParticle.aV;    //Spin the angle a bit
      activeParticle.t += sineTick / frameRate; //Update sine position / transparency
      
      if (activeParticle.a >= TWO_PI) {activeParticle.a = 0; } //Ensure our sine dependent variables remain in a period of 0 to two pi
      if (activeParticle.t >= TWO_PI) {activeParticle.t = 0; }
    }
    if ( clean ) { clean(); } //If we want to clean up the ArrayList this frame, then do so
  }
  
  public particle get (int index)
  {    return childParticles.get(index);  } //A get command, possibly redundant? Makes for a clean interface to leave childParticles invisible
}

class particle
{
  /*
  LEGEND:
    x  -  X position
    y  -  Y position
    vX -  X velocity
    vY -  Y velocity
    s  -  spread rate
    a  -  angle
    aV -  angular velocity
    r,g,b,t, colour with alpha (t)
  */
  float x, y, vX, vY, s, a, aV, r, g, b, t;
  public particle(float _x, float _y, float _vX, float _vY, float _s, float _a, float _aV, float _t, float _r, float _g, float _b)  //Constructor function
  {
    x = _x; y = _y; vX = _vX; vY = _vY; s = _s; a = _a; aV = _aV; t = _t; r = _r; g = _g; b = _b;
  }
}