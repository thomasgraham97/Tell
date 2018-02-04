import processing.net.*;

/***********************
| NETWORKING VARIABLES |
***********************/

Client client;
String dataFromServer;
int[] dataFromServerAsIntArray;
int framesSinceLastCheck;

/*********************
| GRAPHICS VARIABLES |
*********************/

PGraphics pg;      //Consolidate our rendering into one call
PImage    caustic; //Image for our particle system
particleSystem causticsSystem;
  
float sineCounter, sineTick = PI;
float r = 0, g = 0, b = 0, amplitude = 0;

void setup()
{
  fullScreen(P2D); //Set P2D renderer for better performance
  frameRate(60);   //Set a fixed framerate
  
  /*******************
  | NETWORKING SETUP |
  *******************/
  
  client = new Client ( this, "127.0.0.1", 12345 ); 
  
  /*****************
  | GRAPHICS SETUP |
  *****************/
  
  pg = createGraphics (width, height, P2D); //Fill the screen, share a renderer
  pg.noSmooth(); //Improves performance a little
  pg.beginDraw();
    pg.background(0);  //Start on a black background
    pg.fill(0,150);    //Fade to black, alpha manages speed of subtraction
    pg.tint(255,10);    //Make images transparent, alpha manages speed of addition
    pg.imageMode(CENTER);
  pg.endDraw();
  
  caustic = loadImage("caustic.jpg");
  causticsSystem = new particleSystem();
}

void draw()
{  
  background (0,0,0,0);
  
  /***********
  | GRAPHICS |
  ***********/
  
   pg.beginDraw();
        pg.blendMode(BLEND); pg.rect(0,0,width,height);    pg.blendMode(ADD);
        
        causticsSystem.addParticles( frameRate > 24 ? 8:4, (amplitude * 12), r, g, b ); //If the frame rate is getting low avoid spam
        causticsSystem.update( (millis() % 2 == 0) ? true : false );

        for ( int index = 0; index < causticsSystem.size; index++ )
        {
          particle activeParticle = causticsSystem.get(index);
          //pg.tint(max (100, sin (activeParticle.t) * min (r, 255) ), max (100, cos (activeParticle.t) * min (g, 255) ),max (150, tan (activeParticle.t) * min (b, 255) ),  max ( 0.75, sin ( activeParticle.t ) ) * 15 );
          pg.tint
          (
            min ( max ( sin ( activeParticle.t ), 0.75) * activeParticle.r, 255), 
            min ( max ( cos ( activeParticle.t ), 0.75) * activeParticle.g, 255), 
            min ( max ( tan ( activeParticle.t ), 0.75) * activeParticle.b, 255),
            max ( sin ( activeParticle.t) * activeParticle.a * 18.0, 0.75 )
          );
          
           pg.pushMatrix(); 
             pg.translate ( activeParticle.x, activeParticle.y); pg.rotate (activeParticle.a); pg.translate ( -activeParticle.x, -activeParticle.y);
             pg.image(caustic, activeParticle.x, activeParticle.y, activeParticle.s, activeParticle.s );
           pg.popMatrix();
        }
        if (millis() % 2 == 0) { causticsSystem.clean(); }
  pg.endDraw();
  image(pg,0,0);
  
  /*************
  | NETWORKING |
  *************/
  
  if ( framesSinceLastCheck > 4 && client.available() > 0 ) //Every four milliseconds check if a client is available
  {
     dataFromServer = client.readString();
     try { dataFromServer = dataFromServer.substring (0, dataFromServer.indexOf ("\n") ); } //Having only gone up to the newline... 
     catch ( Throwable error ) { println ("Oops"); }
     dataFromServerAsIntArray = int ( split ( dataFromServer, ' ') ); //Split by spaces into array
     
     try { amplitude = max ( (float)(dataFromServerAsIntArray[0] / 1000.0), 0.25 );  } catch (Throwable error) {  amplitude = 0.0;  } //Networking can be bumpy sometimes
     try { r = (float)(dataFromServerAsIntArray[1] / 1000.0);  } catch (Throwable error) {  r = 0.0;  }
     try { g = (float)(dataFromServerAsIntArray[2] / 1000.0);  } catch (Throwable error) {  g = 0.0;  }
     try { b = (float)(dataFromServerAsIntArray[3] / 1000.0);  } catch (Throwable error) {  b = 0.0;  }
     
     framesSinceLastCheck = 0;
  }
  
  framesSinceLastCheck++; 
  
  //Secret diagnostic features
  println ("VISUALS | Frame rate: " + frameRate + " | Particles on display: " + causticsSystem.size + " | Amplitude: " + amplitude + "| RGB: (" + r + ", " + g + ", " + b + ")" );
}


class particleSystem
{
  ArrayList<particle> childParticles = new ArrayList<particle>();
  public int size;
  
  public void addParticles(int particlesToAdd, float spreadRate, float r, float g, float b)
  {
    for ( int index = 0; index < particlesToAdd; index++ )
    {
      particle newParticle = new particle 
      (
        width / 2, height / 2, 
        random(-spreadRate * frameRate,spreadRate * frameRate), 
        random(-spreadRate * frameRate,spreadRate * frameRate), 
        random(-spreadRate,spreadRate),
        random(0, TWO_PI),
        random(-QUARTER_PI / 16, QUARTER_PI / 16),
        random(0, HALF_PI),
        max (25.0, lerp (r, 255, 0.5)), max(25.0, lerp (g, 255, 0.5) ), max ( 25, lerp (b, 255, 0.5) )
      );
      childParticles.add(newParticle);
    }
    size = childParticles.size();
  }
  
  public void clean()
  {
    for ( int index = 0; index < size; index ++ )
    {
      particle activeParticle = childParticles.get(index);
      
      if ( activeParticle.x > width || activeParticle.x < 0 || activeParticle.y > height || activeParticle.y < 0 )
      {
        childParticles.remove(index);
        childParticles.trimToSize();
        size--;
      }
 
      if ( size > 600 && Math.random() > 0.5 ) { childParticles.remove(index); childParticles.trimToSize(); size--; }
    }
    size = childParticles.size();
  }
  
  public void update(boolean clean)
  {
    for ( int index = 0; index < size; index ++ )
    {
      particle activeParticle = childParticles.get(index);
      activeParticle.x += activeParticle.vX / frameRate; activeParticle.y += activeParticle.vY / frameRate;
      activeParticle.s += (max ( abs(activeParticle.vX), abs(activeParticle.vY) ) * 1.25) / frameRate;
      activeParticle.a += activeParticle.aV;
      activeParticle.t += sineTick / frameRate;
      
      if (activeParticle.a >= TWO_PI) {activeParticle.a = 0; }
      if (activeParticle.t >= TWO_PI) {activeParticle.t = 0; }
    }
    if ( clean ) { clean(); }
  }
  
  public particle get (int index)
  {
    return childParticles.get(index);
  }
}

class particle
{
  float x, y, vX, vY, s, a, aV, r, g, b, t;
  public particle(float _x, float _y, float _vX, float _vY, float _s, float _a, float _aV, float _t, float _r, float _g, float _b)
  {
    x = _x; y = _y; vX = _vX; vY = _vY; s = _s; a = _a; aV = _aV; t = _t; r = _r; g = _g; b = _b;
  }
}