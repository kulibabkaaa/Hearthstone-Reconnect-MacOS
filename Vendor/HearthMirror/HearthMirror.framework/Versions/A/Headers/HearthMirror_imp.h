/*
 *  HearthMirror.h
 *  HearthMirror wrapper class
 *
 *  Created by Istvan Fehervari on 26/12/2016.
 *  Copyright © 2016 com.ifehervari. All rights reserved.
 *
 */

#import <Foundation/Foundation.h>
#define EXPORT __attribute__((visibility("default")))

@interface MirrorCombatHistory: NSObject
    @property NSNumber *_Nonnull ownerId;
    @property NSNumber *_Nonnull opponentId;
    @property NSNumber *_Nonnull damageTarget;
    @property NSNumber *_Nonnull damage;
    @property NSNumber *_Nonnull winStreak;
    @property BOOL isDefeated;
@end

@interface MirrorBrawlInfo: NSObject
    @property NSNumber *_Nullable maxWins;
    @property NSNumber *_Nullable maxLosses;
    @property BOOL isSessionBased;
    @property NSNumber *_Nonnull wins;
    @property NSNumber *_Nonnull losses;
    @property NSNumber *_Nonnull gamesPlayed;
    @property NSNumber *_Nonnull winStreak;
@end

@interface MirrorDungeonInfo: NSObject
    @property NSNumber *_Nonnull gameSaveId;
    @property NSArray<NSNumber*> *_Nonnull bossesDefeated;
    @property NSNumber *_Nonnull bossesLostTo;
    @property NSNumber *_Nonnull nextBossHealth;
    @property NSNumber *_Nonnull heroHealth;
    @property NSArray<NSNumber*> *_Nonnull dbfIds;
    @property NSArray<NSNumber*> *_Nonnull cardsAddedToDeck;
    @property NSNumber *_Nonnull heroCardClass;
    @property NSArray<NSNumber*> *_Nonnull passiveBuffs;
    @property NSNumber *_Nonnull nextBossDbfId;
    @property NSArray<NSNumber*> *_Nonnull lootA;
    @property NSArray<NSNumber*> *_Nonnull lootB;
    @property NSArray<NSNumber*> *_Nonnull lootC;
    @property NSArray<NSNumber*> *_Nonnull treasure;
    @property NSArray<NSNumber*> *_Nonnull lootHistory;
    @property NSNumber *_Nonnull playerChosenLoot;
    @property NSNumber *_Nonnull playerChosenTreasure;
    @property BOOL runActive;
    @property NSNumber *_Nonnull heroClass;
    @property NSArray<NSNumber*> *_Nonnull shrines;
    @property NSNumber *_Nonnull playerChosenShrine;
    @property NSNumber *_Nonnull selectedDeckId;
    @property NSNumber *_Nonnull selectedHeroPower;
    @property NSNumber *_Nonnull selectedLoadoutTreasureDbId;
    @property NSNumber *_Nonnull cardSet;
    @property NSNumber *_Nonnull heroCardDbId;
    @property NSNumber *_Nonnull playerSelectedHeroDbId;
@end

@interface MirrorAdventureConfig: NSObject
    @property NSNumber *_Nonnull selectedAdventure;
    @property NSNumber *_Nonnull selectedMode;
    @property NSNumber *_Nonnull selectedMission;
    @property NSNumber *_Nonnull selectedDeckId;
@end

@interface MirrorGameServerInfo: NSObject
    @property NSString *_Nonnull address;
    @property NSString *_Nonnull auroraPassword;
    @property NSNumber *_Nonnull clientHandle;
    @property NSNumber *_Nonnull gameHandle;
    @property NSNumber *_Nonnull mission;
    @property NSNumber *_Nonnull port;
    @property BOOL resumable;
    @property BOOL spectatorMode;
    @property NSString *_Nonnull spectatorPassword;
    @property NSString *_Nonnull version;
@end

@interface MirrorMedalInfo: NSObject
    @property NSNumber *_Nonnull LeagueId;
    @property NSNumber *_Nonnull Stars;
    @property NSNumber *_Nonnull StarsPerWin;
    @property NSNumber *_Nonnull StarLevel;
    @property NSNumber *_Nonnull LegendRank;
@end

@interface MirrorAccountId: NSObject
    @property NSNumber *_Nonnull lo;
    @property NSNumber *_Nonnull hi;
@end

@interface MirrorBattleTag: NSObject
    @property NSString *_Nonnull name;
    @property NSString *_Nonnull number;
@end

@interface MirrorPlayer: NSObject
    @property NSString *_Nonnull name;
    @property NSNumber *_Nonnull playerId;
    @property NSNumber *_Nonnull standardRank;
    @property NSNumber *_Nonnull wildRank;
    @property NSNumber *_Nonnull classicRank;
    @property NSNumber *_Nonnull twistRank;
    @property NSNumber *_Nonnull cardBackId;
    @property MirrorMedalInfo *_Nonnull standardMedalInfo;
    @property MirrorMedalInfo *_Nonnull wildMedalInfo;
    @property MirrorMedalInfo *_Nonnull classicMedalInfo;
    @property MirrorMedalInfo *_Nonnull twistMedalInfo;
    @property MirrorAccountId *_Nonnull accountId;
    @property MirrorBattleTag *_Nullable battleTag;
@end

@interface MirrorMatchInfo: NSObject
    @property MirrorPlayer *_Nonnull localPlayer;
    @property MirrorPlayer *_Nonnull opposingPlayer;
    @property NSNumber *_Nonnull brawlSeasonId;
    @property NSNumber *_Nonnull missionId;
    @property NSNumber *_Nonnull rankedSeasonId;
    @property NSNumber *_Nonnull gameType;
    @property NSNumber *_Nonnull formatType;
    @property BOOL spectator;
@end

@interface MirrorHeroLevel: NSObject
    @property NSNumber *_Nonnull heroClass;
    @property NSNumber *_Nonnull level;
    @property NSNumber *_Nonnull maxLevel;
    @property NSNumber *_Nonnull xp;
    @property NSNumber *_Nonnull maxXp;
@end

@interface MirrorCard: NSObject
    @property NSString *_Nonnull cardId;
    @property NSNumber *_Nonnull count;
    @property NSNumber *_Nonnull premium;
    @property NSNumber *_Nonnull trial;
@end

@interface MirrorDeck: NSObject
    @property NSNumber *_Nonnull id;
    @property NSString *_Nonnull name;
    @property NSString *_Nonnull hero;
    @property NSNumber *_Nonnull formatType;
    @property NSNumber *_Nonnull type;
    @property NSNumber *_Nonnull seasonId;
    @property NSNumber *_Nonnull cardBackId;
    @property NSNumber *_Nonnull heroPremium;
    @property NSArray<MirrorCard*> *_Nonnull cards;
    @property NSDictionary<NSString *, NSArray<MirrorCard *>*>* _Nonnull sideboards;
@end

@interface MirrorTemplateDeck: NSObject
    @property NSNumber *_Nonnull id;
    @property NSString *_Nonnull title;
    @property NSNumber *_Nonnull sortOrder;
    @property NSNumber *_Nonnull clazz;
    @property NSArray<NSNumber*> *_Nonnull cards;
    @property NSNumber *_Nonnull event;
    @property NSNumber *_Nonnull formatType;
@end

@interface MirrorRewardData: NSObject
@end

@interface MirrorArcaneDustRewardData : MirrorRewardData
    @property NSNumber *_Nonnull amount;
@end

@interface MirrorBoosterPackRewardData : MirrorRewardData
    @property NSNumber *_Nonnull boosterId;
    @property NSNumber *_Nonnull count;
@end

@interface MirrorCardRewardData : MirrorRewardData
    @property NSString *_Nonnull cardId;
    @property NSNumber *_Nonnull count;
    @property BOOL premium;
@end

@interface MirrorCardBackRewardData : MirrorRewardData
    @property NSNumber *_Nonnull cardbackId;
@end

@interface MirrorForgeTicketRewardData : MirrorRewardData
    @property NSNumber *_Nonnull quantity;
@end

@interface MirrorGoldRewardData : MirrorRewardData
    @property NSNumber *_Nonnull amount;
@end

@interface MirrorMountRewardData : MirrorRewardData
    @property NSNumber *_Nonnull mountType;
@end

@interface MirrorArenaInfo: NSObject
    @property MirrorDeck *_Nonnull deck;
    @property NSNumber *_Nonnull losses;
    @property NSNumber *_Nonnull wins;
    @property NSNumber *_Nonnull currentSlot;
    @property NSArray<MirrorRewardData*> *_Nonnull rewards;
    @property NSNumber *_Nonnull season;

    @property BOOL isUnderground;
    @property NSNumber *_Nonnull sessionState;
    @property MirrorDeck *_Nonnull redraftDeck;
    @property NSNumber *_Nonnull redraftCurrentSlot;
@end

@interface MirrorDraftChoices: NSObject
    @property NSArray<MirrorCard*> *_Nonnull choices;
    @property NSNumber *_Nonnull version;
    @property NSArray<NSArray<MirrorCard*>*> *_Nonnull packages;
@end

@interface MirrorPlayerRecord: NSObject
    @property NSNumber *_Nonnull type;
    @property NSNumber *_Nonnull data;
    @property NSNumber *_Nonnull wins;
    @property NSNumber *_Nonnull losses;
    @property NSNumber *_Nonnull ties;
@end

@interface MirrorCollection: NSObject
    @property NSArray<MirrorCard*>*_Nonnull cards;
    @property NSArray<NSNumber*> *_Nonnull cardbacks;
    @property NSNumber *_Nonnull favoriteCardback;
    @property NSDictionary<NSNumber*, MirrorCard*> *_Nonnull favoriteHeroes;
    @property NSNumber *_Nonnull dust;
    @property NSNumber *_Nonnull gold;
    @property NSArray<MirrorPlayerRecord*> *_Nonnull playerRecords;
@end

@interface MirrorRatingChange: NSObject
    @property NSNumber *_Nonnull ratingNew;
    @property NSNumber *_Nonnull ratingChange;
@end

@interface MirrorMedalData: NSObject
    @property MirrorMedalInfo *_Nonnull wild;
    @property MirrorMedalInfo *_Nonnull standard;
    @property MirrorMedalInfo *_Nonnull classic;
    @property MirrorMedalInfo *_Nonnull twist;
@end

@interface MirrorRewardTrackData: NSObject
    @property NSNumber *_Nonnull level;
    @property BOOL premiunRewardsUnlocked;
    @property NSNumber *_Nonnull rewardTrackId;
    @property NSNumber *_Nonnull unclaimed;
    @property NSNumber *_Nonnull xp;
    @property NSNumber *_Nonnull xpBonusPercent;
    @property NSNumber *_Nonnull xpNeeded;
@end

@interface MirrorMercenariesMapInfo: NSObject
    @property NSNumber *_Nonnull seed;
    @property NSNumber *_Nonnull turnsTaken;
    @property BOOL defeatedFinalBoss;
    @property NSNumber *_Nonnull completedNodes;
@end

@interface MirrorMercenaryData: NSObject
    @property NSNumber *_Nonnull ID;
    @property NSNumber *_Nonnull currencyAmount;
@end

@interface MirrorMercenariesVisitorTask: NSObject
    @property NSNumber *_Nonnull visitorID;
    @property NSNumber *_Nonnull taskChainProgress;
    @property NSNumber *_Nonnull taskId;
    @property NSNumber *_Nonnull progress;
    @property NSString *_Nonnull visitorName;
    @property NSString *_Nonnull bountyName;
    @property NSString *_Nonnull bountySet;
    @property NSArray<NSString *> *_Nonnull additionalMercenaries;
    @property NSNumber *_Nonnull visitorCardDbf;
    @property BOOL bountyHeroic;
@end

@interface MirrorMercenariesTaskData: NSObject
    @property NSNumber *_Nonnull ID;
    @property NSNumber *_Nonnull mercenaryDefaultDbfId;
    @property NSString *_Nonnull title;
    @property NSString *_Nonnull taskDescription;
    @property NSNumber *_Nonnull quota;
@end

@interface MirrorAbility: NSObject
    @property NSNumber *_Nonnull ID;
    @property NSNumber *_Nonnull tier;
@end

@interface MirrorArtVariation: NSObject
    @property NSNumber *_Nonnull dbfId;
    @property BOOL equipped;
    @property NSNumber *_Nonnull premium;
@end

@interface MirrorCollectionMercenary: NSObject
    @property NSNumber *_Nonnull ID;
    @property NSNumber *_Nonnull level;
    @property NSNumber *_Nonnull currencyAmount;
    @property NSArray<MirrorAbility *> *_Nonnull abilities;
    @property NSArray<MirrorAbility *> *_Nonnull equipments;
    @property NSArray<MirrorArtVariation *> *_Nonnull artVariations;
@end

@interface MirrorCardChoices: NSObject
    @property BOOL isVisible;
    @property NSArray<NSString *> *_Nonnull cards;
@end

@interface MirrorSceneMgrState: NSObject
    @property NSNumber *_Nonnull prevMode;
    @property NSNumber *_Nonnull mode;
    @property NSNumber *_Nonnull nextMode;
    @property BOOL sceneLoaded;
    @property BOOL transitioning;
@end

@interface MirrorDeckPickerState: NSObject
    @property NSNumber *_Nonnull visualsFormatType;
    @property BOOL isModeSwitching;
    @property NSNumber *_Nullable selectedDeck;
    @property NSNumber *_Nullable selectedTemplateDeck;
    @property BOOL setRotationOpen;
@end

@interface MirrorCollectionDeckBoxVisual: NSObject
    @property NSNumber *_Nullable deckId;
    @property NSNumber *_Nullable deckTemplateId;
    @property BOOL isShowingInvalidCardCount;
    @property NSNumber *_Nonnull invalidSideboardCardCount;
    @property NSNumber *_Nonnull missingSideboardCardCount;
    @property BOOL isFocused;
    @property BOOL isSelected;
@end

@interface MirrorBattlegroundRatingInfo: NSObject
    @property NSNumber *_Nonnull rating;
    @property NSNumber *_Nonnull duosRating;
@end

@interface MirrorBattlegroundsTeammateBoardStateEntity: NSObject
    @property NSString *_Nonnull cardId;
    @property NSDictionary<NSNumber *, NSNumber *> *_Nonnull tags;
@end

@interface MirrorBattlegroundsTeammateBoardState: NSObject
    @property BOOL viewingTeammate;
    @property NSArray<NSString *> *_Nullable mulliganHeroes;
    @property NSArray<MirrorBattlegroundsTeammateBoardStateEntity *> *_Nonnull entities;
@end

@interface MirrorBigCardState: NSObject
    @property NSArray<NSNumber *> *_Nonnull tooltipHeights;
    @property NSArray<NSNumber *> *_Nonnull enchantmentHeights;
    @property NSString *_Nonnull cardId;
    @property NSNumber *_Nonnull zonePosition;
    @property NSNumber *_Nonnull zoneSize;
    @property NSNumber *_Nonnull side;
    @property BOOL isHand;
@end

@interface MirrorDiscoverState: NSObject
    @property NSString *_Nonnull cardId;
    @property NSNumber *_Nonnull zoneSize;
    @property NSNumber *_Nonnull zonePosition;
@end

@interface MirrorBoardCard: NSObject
    @property NSString *_Nonnull cardId;
    @property NSNumber *_Nullable entityId;
    @property NSNumber *_Nonnull zonePosition;
    @property BOOL hovered;
@end

@interface MirrorSpecialShopChoicesState: NSObject
    @property BOOL isActive;
    @property NSNumber *_Nonnull mousedOverSlot;
    @property NSArray<MirrorBoardCard *> *_Nonnull boardCards;
@end

@interface MirrorBattlegroundsLobbyPlayer: NSObject
    @property MirrorAccountId *_Nonnull accountId;
    @property NSString *_Nonnull heroCardId;
    @property NSString *_Nonnull name;
@end

@interface MirrorBattlegroundsLobbyInfo: NSObject
    @property NSString *_Nonnull gameUuid;
    @property NSArray<MirrorBattlegroundsLobbyPlayer *> *_Nonnull players;
@end

@interface MirrorMulliganCardState: NSObject
    @property NSString *_Nonnull cardId;
    @property NSNumber *_Nonnull zonePosition;
    @property NSNumber *_Nonnull state;
@end

@interface MirrorMulliganState: NSObject
    @property BOOL waitingForUserInput;
    @property NSArray<MirrorMulliganCardState *> *_Nonnull mulliganCards;
@end

EXPORT @interface HearthMirror : NSObject

-(nonnull instancetype) initWithPID:(pid_t)pid withBlocking:(BOOL)blocking NS_SWIFT_NAME(init(pid:blocking:));

/** Returns the BattleTag as a single string in the following format: name#number. */
-(nullable NSString*) getBattleTag;
    
-(nonnull MirrorCollection*) getCollection;

-(nonnull NSArray<MirrorHeroLevel*>*) getHeroLevels;

-(nullable MirrorGameServerInfo*) getGameServerInfo;

-(nullable NSNumber*) getGameType;

-(nullable MirrorMatchInfo*) getMatchInfo;

-(nullable NSNumber*) getFormat;

-(BOOL) isSpectating;

-(nullable MirrorAccountId*) getAccountId;

-(nonnull NSArray<MirrorDeck*>*) getDecks;

-(nonnull NSArray<MirrorDeck*>*) getDecksFiltered:(NSArray<NSNumber*>*_Nonnull) decks;

-(nullable MirrorTemplateDeck*) getTemplateDeckByDeckTemplateId:(int) deckTemplateId;

-(nullable NSNumber *) findDeckTemplateIdForDeckIdInternal:(int) deckId;

-(nullable NSNumber*) getSelectedDeck;

-(nullable NSNumber*) getSelectedDeckInMenu __deprecated;

-(nullable NSNumber*) getDeckPickerSelectedDeck;

-(nullable MirrorDeckPickerState *) getDeckPickerState;

-(nullable NSMutableArray *) getDeckPickerDecksOnPage;

-(nullable MirrorDeck*) getEditedDeck;

-(nullable MirrorArenaInfo*) getArenaDeck;

-(nullable MirrorDraftChoices*) getArenaDraftChoices;

-(nonnull NSArray<MirrorCard*>*) getPackCards;

-(nullable MirrorBrawlInfo *) getBrawlInfo;

-(nullable MirrorDungeonInfo *) getDungeonInfo:(int) key;

-(nullable MirrorDungeonInfo *) getPVPDungeonInfo;

-(nullable MirrorDeck *) getPVPDungeonSeedDeck;

-(nullable NSArray<NSNumber *> *) getDungeonDeck:(int) deckId;

-(nullable MirrorRatingChange *) getBattlegroundsRatingChange;

-(nullable MirrorBattlegroundRatingInfo *) getBattlegroundsRatingInfo;

-(nonnull NSArray<NSNumber*>*) getAvailableBattlegroundsRaces;

-(nonnull NSArray<NSNumber*>*) getUnavailableBattlegroundsRaces;

-(nullable MirrorMedalData*) getMedalData;

-(nullable MirrorAdventureConfig*) getAdventureConfig;

-(nullable NSNumber *) getScenarioDeckId:(int) deckId;

-(nullable MirrorRewardTrackData *) getRewardTrackData:(int) type;

-(nullable NSDictionary<NSNumber *, NSArray<MirrorCombatHistory *>*>*) getCombatHistory;

-(nullable NSNumber *) getMercenariesRating;

-(nullable MirrorMercenariesMapInfo *) getMercenariesMapInfo;

-(nullable MirrorRatingChange *) getMercenariesRatingChange;

-(nonnull NSArray<MirrorMercenaryData *>*) getMercenariesInCollection;

-(nonnull NSArray<MirrorMercenariesVisitorTask *>*) getMercenariesVisitorTasks;

-(nonnull NSArray<MirrorMercenariesTaskData *>*) getMercenariesTaskData;

-(nonnull NSArray<MirrorCollectionMercenary *>*) getMercenariesCollection;

-(nullable MirrorCardChoices *) getCardChoices;

-(nullable MirrorSpecialShopChoicesState *) getSpecialShopChoices;

-(nonnull NSNumber *) getFindGameState;

-(BOOL) isShopOpen;

-(BOOL) isJournalOpen;

-(BOOL) isPopupShowing;

-(BOOL) isBlurActive;

-(BOOL) isMulliganWaitingForUserInput;

-(BOOL) isFriendsListVisible;

-(BOOL) isGameMenuVisible;

-(BOOL) isOptionsMenuVisible;

-(nullable NSString *) getLogSessionDir;

-(nullable MirrorSceneMgrState *) getSceneMgrState;

-(nonnull NSNumber *) getSelectedBattlegroundsGameMode;

-(nullable NSNumber *) getBattlegroundsLeaderboardHoveredEntityId;

-(nullable MirrorBattlegroundsTeammateBoardState *) getBattlegroundsTeammateBoardState;

-(nullable MirrorBigCardState *) getBigCardState;

-(nullable MirrorDiscoverState *) getDiscoverState;

-(nullable MirrorBattlegroundsLobbyInfo *) getBattlegroundsLobbyInfo;

-(nullable MirrorMulliganState *) getMulliganState;

@end

