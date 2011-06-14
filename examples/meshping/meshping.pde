/*
 Copyright (C) 2011 James Coliz, Jr. <maniacbug@ymail.com>

 This program is free software; you can redistribute it and/or
 modify it under the terms of the GNU General Public License
 version 2 as published by the Free Software Foundation.
 */

/**
 * Example of pinging across a mesh network
 *
 * Using this sketch, each node will send a ping to every other node
 * in the network every few seconds. 
 * The RF24Network library will route the message across
 * the mesh to the correct node.
 *
 * This sketch is greatly complicated by the fact that at startup time, each
 * node (including the base) has no clue what nodes are alive.  So,
 * each node builds an array of nodes it has heard about.  The base
 * periodically sends out its whole known list of nodes to everyone.
 *
 * To see the underlying frames being relayed, compile RF24Network with
 * #define SERIAL_DEBUG.
 *
 * The logical node address of each node is set in EEPROM.  The nodeconfig
 * module handles this by listening for a digit (0-9) on the serial port,
 * and writing that number to EEPROM.
 */

#include <avr/pgmspace.h>
#include <RF24Network.h>
#include <RF24.h>
#include <SPI.h>
#include "nodeconfig.h"
#include "printf.h"

// Avoid spurious warnings
#undef PROGMEM 
#define PROGMEM __attribute__(( section(".progmem.data") )) 
#undef PSTR 
#define PSTR(s) (__extension__({static prog_char __c[] PROGMEM = (s); &__c[0];}))

RF24 radio(8,9);
RF24Network network(radio);

// Our node address
uint16_t this_node;

// The message that we send is just a ulong, containing the time
unsigned long message;

// Delay manager to send pings regularly
const unsigned long interval = 2000; // ms
unsigned long last_time_sent;

// Array of nodes we are aware of
const short max_active_nodes = 10;
uint16_t active_nodes[max_active_nodes];
short num_active_nodes = 0;
short next_ping_node_index = 0;

// Prototypes for functions to send & handle messages
bool send_T(uint16_t to);
bool send_N(uint16_t to);
void handle_T(RF24NetworkHeader& header);
void handle_N(RF24NetworkHeader& header);
void add_node(uint16_t node);

void setup(void)
{
  //
  // Print preamble
  //
  
  Serial.begin(57600);
  printf_begin();
  printf("\n\rRF24Network/examples/meshping/\n\r");
  
  //
  // Pull node address out of eeprom 
  //

  // Which node are we?
  this_node = nodeconfig_read();

  //
  // Bring up the RF network
  //

  SPI.begin();
  radio.begin();
  network.begin(/*channel*/ 100, /*node address*/ this_node, /*directionality*/ RF24_NET_BIDIRECTIONAL);
}

void loop(void)
{
  // Pump the network regularly
  network.update();

  // Is there anything ready for us?
  while ( network.available() )
  {
    // If so, grab it and print it out
    RF24NetworkHeader header;
    network.peek(header);

    // Process the node, based on its type.
    switch (header.type)
    {
    case 'T':
      handle_T(header);
      break;
    case 'N':
      handle_N(header);
      break;
    default:
      printf_P(PSTR("*** WARNING *** Unknown message type %c\n\r"),header.type);
      break;
    };
  }

  // Send a ping to the other guy every 'interval' ms
  unsigned long now = millis();
  if ( now - last_time_sent >= interval )
  {
    last_time_sent = now;

    // Who should we send to?
    // By default, send to base
    uint16_t to = 0;
    if ( num_active_nodes )
    {
      to = active_nodes[next_ping_node_index++];
      // Have we rolled over?
      if ( next_ping_node_index > num_active_nodes )
      {
	// Next time start at the beginning
	next_ping_node_index = 0;
	// This time, send to node 0.
	to = 0;
      }
    }

    bool ok;
    if ( this_node > 0 || to == 0 )
      // Normal nodes send a 'T' ping
      ok = send_T(to);
    else
      // Base node sends the current active nodes out
      ok = send_N(to);

    // Notify us of the result
    if (ok)
    {
      printf_P(PSTR("%lu: APP Send ok\n\r"),millis());
    }
    else
    {
      printf_P(PSTR("%lu: APP Send failed\n\r"),millis());

      // Try sending at a different time next time
      last_time_sent -= 100;
    }
  }

  // Listen for a new node address
  nodeconfig_listen();
}

/**
 * Send a 'T' message, the current time
 */
bool send_T(uint16_t to)
{
  message = millis();
  RF24NetworkHeader header(/*to node*/ to, /*type*/ 'T' /*Time*/);
  
  printf_P(PSTR("---------------------------------\n\r"));
  printf_P(PSTR("%lu: APP Sending %lu to 0%o...\n\r"),millis(),message,to);
  return network.write(header,&message,sizeof(unsigned long));
}

/**
 * Send an 'N' message, the active node list
 */
bool send_N(uint16_t to)
{
  RF24NetworkHeader header(/*to node*/ to, /*type*/ 'N' /*Time*/);
  
  printf_P(PSTR("---------------------------------\n\r"));
  printf_P(PSTR("%lu: APP Sending active nodes to 0%o...\n\r"),millis(),to);
  return network.write(header,active_nodes,sizeof(active_nodes));
}

/**
 * Handle a 'T' message
 *
 * Add the node to the list of active nodes
 */
void handle_T(RF24NetworkHeader& header)
{
  network.read(header,&message,sizeof(unsigned long));
  printf_P(PSTR("%lu: APP Received %lu from 0%o\n\r"),millis(),message,header.from_node);

  // If this message is from ourselves or the base, don't bother adding it to the active nodes.
  if ( header.from_node != this_node || header.from_node > 0 )
    add_node(header.from_node);
}

/**
 * Handle an 'N' message, the active node list
 */
void handle_N(RF24NetworkHeader& header)
{
  static uint16_t incoming_nodes[max_active_nodes];

  network.read(header,&incoming_nodes,sizeof(incoming_nodes));
  printf_P(PSTR("%lu: APP Received nodes from 0%o\n\r"),millis(),header.from_node);

  int i = 0;
  while ( i < max_active_nodes && incoming_nodes[i] > 0 )
    add_node(incoming_nodes[i++]);
}

/**
 * Add a particular node to the current list of active nodes
 */
void add_node(uint16_t node)
{
  // Do we already know about this node?
  short i = num_active_nodes;
  while (i--)
  {
    if ( active_nodes[i] == node )
      break;
  }
  // If not, add it to the table
  if ( i == -1 && num_active_nodes < max_active_nodes )
  {
    active_nodes[num_active_nodes++] = node; 
    printf_P(PSTR("%lu: APP Added 0%o to list of active nodes.\n\r"),millis(),node);
  }
}

// vim:ai:cin:sts=2 sw=2 ft=cpp
