/* ChatTableViewController.m
 *
 * Copyright (C) 2012  Belledonne Comunications, Grenoble, France
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 */

#import "ChatsListTableView.h"
#import "UIChatCell.h"

#import "FileTransferDelegate.h"

#import "linphone/linphonecore.h"
#import "PhoneMainView.h"
#import "Utils.h"

@implementation ChatsListTableView

#pragma mark - Lifecycle Functions

- (instancetype)init {
	self = super.init;
	if (self) {
		_data = nil;
		_nbOfChatRoomToDelete = 0;
		_waitView.hidden = TRUE;
	}
	return self;
}

#pragma mark - ViewController Functions

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	self.tableView.accessibilityIdentifier = @"Chat list";
	[self loadData];
	_chatRooms = NULL;
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	// we cannot do that in viewWillAppear because we will change view while previous transition
	// was not finished, leading to "[CALayer retain]: message sent to deallocated instance" error msg
	if (IPAD && [self totalNumberOfItems] > 0) {
		[PhoneMainView.instance changeCurrentView:ChatConversationView.compositeViewDescription];
	}
}

- (void)viewWillDisappear:(BOOL)animated {
	while (_chatRooms) {
		LinphoneChatRoom *chatRoom = (LinphoneChatRoom *)_chatRooms->data;
		if (!chatRoom)
			continue;

		LinphoneChatRoomCbs *cbs = linphone_chat_room_get_callbacks(chatRoom);
		linphone_chat_room_cbs_set_state_changed(cbs, NULL);
		linphone_chat_room_cbs_set_user_data(cbs, NULL);
		_chatRooms = _chatRooms->next;
	}
}

- (void)layoutSubviews {
	[self.tableView layoutSubviews];

	CGSize contentSize = self.tableView.contentSize;
	contentSize.width = self.tableView.bounds.size.width;
	self.tableView.contentSize = contentSize;
}

#pragma mark -

static int sorted_history_comparison(LinphoneChatRoom *to_insert, LinphoneChatRoom *elem) {
	time_t new = linphone_chat_room_get_last_update_time(to_insert);
	time_t old = linphone_chat_room_get_last_update_time(elem);
	if (new < old)
		return 1;
	else if (new > old)
		return -1;

	return 0;
}

- (MSList *)sortChatRooms {
	MSList *sorted = nil;
	const MSList *unsorted = linphone_core_get_chat_rooms(LC);
	const MSList *iter = unsorted;

	while (iter) {
		// store last message in user data
		LinphoneChatRoom *chat_room = iter->data;
		sorted = bctbx_list_insert_sorted(sorted, chat_room, (bctbx_compare_func)sorted_history_comparison);
		iter = iter->next;
	}
	return sorted;
}

- (void)loadData {
	_data = [self sortChatRooms];
	[super loadData];

	if (IPAD) {
		int idx = bctbx_list_index(_data, VIEW(ChatConversationView).chatRoom);
		// if conversation view is using a chatroom that does not exist anymore, update it
		if (idx != -1) {
			NSIndexPath *indexPath = [NSIndexPath indexPathForRow:idx inSection:0];
			[self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
		} else if (![self selectFirstRow]) {
			ChatConversationCreateView *view = VIEW(ChatConversationCreateView);
			view.tableController.notFirstTime = FALSE;
			[PhoneMainView.instance changeCurrentView:view.compositeViewDescription];
		}
	}
}

- (void)markCellAsRead:(LinphoneChatRoom *)chatRoom {
	int idx = bctbx_list_index(_data, VIEW(ChatConversationView).chatRoom);
	NSIndexPath *indexPath = [NSIndexPath indexPathForRow:idx inSection:0];
	if (IPAD) {
		UIChatCell *cell = (UIChatCell *)[self.tableView cellForRowAtIndexPath:indexPath];
		[cell updateUnreadBadge];
	}
}

#pragma mark - UITableViewDataSource Functions

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return bctbx_list_size(_data);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	static NSString *kCellId = @"UIChatCell";
	UIChatCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellId];
	if (cell == nil)
		cell = [[UIChatCell alloc] initWithIdentifier:kCellId];


	[cell setChatRoom:(LinphoneChatRoom *)bctbx_list_nth_data(_data, (int)[indexPath row])];
	[super accessoryForCell:cell atPath:indexPath];
	return cell;
}

#pragma mark - UITableViewDelegate Functions

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[super tableView:tableView didSelectRowAtIndexPath:indexPath];
	if (![self isEditing]) {
		LinphoneChatRoom *chatRoom = (LinphoneChatRoom *)bctbx_list_nth_data(_data, (int)[indexPath row]);
		ChatConversationView *view = VIEW(ChatConversationView);
		view.chatRoom = chatRoom;
		// on iPad, force unread bubble to disappear by reloading the cell
		if (IPAD) {
			UIChatCell *cell = (UIChatCell *)[tableView cellForRowAtIndexPath:indexPath];
			[cell updateUnreadBadge];
		}
		[PhoneMainView.instance changeCurrentView:view.compositeViewDescription];
	}
}

void deletion_chat_room_state_changed(LinphoneChatRoom *cr, LinphoneChatRoomState newState) {
	ChatsListTableView *view = (__bridge ChatsListTableView *)linphone_chat_room_cbs_get_user_data(linphone_chat_room_get_callbacks(cr)) ?: NULL;
	if (!view)
		return;
	
	if (newState == LinphoneChatRoomStateDeleted || newState == LinphoneChatRoomStateTerminationFailed) {
		LinphoneChatRoomCbs *cbs = linphone_chat_room_get_callbacks(cr);
		linphone_chat_room_cbs_set_state_changed(cbs, NULL);
		linphone_chat_room_cbs_set_user_data(cbs, NULL);
		view.chatRooms = bctbx_list_remove(view.chatRooms, cr);
		view.nbOfChatRoomToDelete--;
	}

	if (view.nbOfChatRoomToDelete == 0) {
		// will force a call to [self loadData]
		[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneMessageReceived object:view];
		view.waitView.hidden = TRUE;
	}
}

- (void) deleteChatRooms {
	_waitView.hidden = FALSE;
	bctbx_list_t *chatRooms = bctbx_list_copy(_chatRooms);
	while (chatRooms) {
		LinphoneChatRoom *chatRoom = (LinphoneChatRoom *)chatRooms->data;
		if (!chatRoom)
			continue;

		_nbOfChatRoomToDelete++;
		LinphoneChatRoomCbs *cbs = linphone_chat_room_get_callbacks(chatRoom);
		linphone_chat_room_cbs_set_state_changed(cbs, deletion_chat_room_state_changed);
		linphone_chat_room_cbs_set_user_data(cbs, (__bridge void*)self);

		FileTransferDelegate *ftdToDelete = nil;
		for (FileTransferDelegate *ftd in [LinphoneManager.instance fileTransferDelegates]) {
			if (linphone_chat_message_get_chat_room(ftd.message) == chatRoom) {
				ftdToDelete = ftd;
				break;
			}
		}
		[ftdToDelete cancel];

		linphone_core_delete_chat_room(LC, chatRoom);
		chatRooms = chatRooms->next;
	}
}

- (void)tableView:(UITableView *)tableView
	commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
	 forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (editingStyle == UITableViewCellEditingStyleDelete) {
		LinphoneChatRoom *chatRoom = (LinphoneChatRoom *)bctbx_list_nth_data(_data, (int)[indexPath row]);
		NSString *msg = (LinphoneChatRoomCapabilitiesOneToOne & linphone_chat_room_get_capabilities(chatRoom))
			? [NSString stringWithFormat:NSLocalizedString(@"Do you really want to delete this conversation?", nil)]
			: [NSString stringWithFormat:NSLocalizedString(@"Do you really want to delete and leave this conversation?", nil)];
		[UIConfirmationDialog ShowWithMessage:msg
								cancelMessage:nil
							   confirmMessage:nil
								onCancelClick:^() {}
						  onConfirmationClick:^() {
							  _chatRooms = bctbx_list_new((void *)chatRoom);
							  [self deleteChatRooms];
						  }];
	}
}

- (void)removeSelectionUsing:(void (^)(NSIndexPath *))remover {
	_chatRooms = NULL;
	// we must iterate through selected items in reverse order
	[self.selectedItems sortUsingComparator:^(NSIndexPath *obj1, NSIndexPath *obj2) {
		return [obj2 compare:obj1];
	}];
	NSArray *copy = [[NSArray alloc] initWithArray:self.selectedItems];
	for (NSIndexPath *indexPath in copy) {
		LinphoneChatRoom *chatRoom = (LinphoneChatRoom *)bctbx_list_nth_data(_data, (int)[indexPath row]);
		_chatRooms = bctbx_list_append(_chatRooms, chatRoom);
	}
	[self deleteChatRooms];
	[self.selectedItems removeAllObjects];
	[self setEditing:NO animated:YES];
}

@end
