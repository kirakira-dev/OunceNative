#pragma once
#import <GameController/GameController.h>
void dm_motion_gamecontroller_read(GCMotion *motion);
// Called on the main queue when the connected-controller list changes.
void dm_motion_gamecontroller_update(NSArray<GCController *> *controllers);
