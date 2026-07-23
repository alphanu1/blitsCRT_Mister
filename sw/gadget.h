/* SPDX-License-Identifier: MIT */
#ifndef BLITSCRT_GADGET_H
#define BLITSCRT_GADGET_H

struct blitscrt_dev;
struct blitscrt_gadget;

struct blitscrt_gadget *blitscrt_gadget_open(const char *ffs_path,
					     struct blitscrt_dev *dev);
int  blitscrt_gadget_run(struct blitscrt_gadget *g);
void blitscrt_gadget_stop(struct blitscrt_gadget *g);
void blitscrt_gadget_close(struct blitscrt_gadget *g);

#endif
