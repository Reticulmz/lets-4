import collections
import json
import os
import sys
import traceback
from urllib.parse import urlencode

import requests
import tornado.gen
import tornado.web

import secret.achievements.utils
from common import generalUtils
from common.constants import gameModes
from common.constants import mods
from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from constants import rankedStatuses
from helpers import aeshelper
from helpers import leaderboardHelper
from objects import beatmap
from objects import glob
from objects import score
from objects import scoreboard
from helpers.generalHelper import zingonify
from objects.charts import BeatmapChart, OverallChart

from secret import achievements, butterCake
from secret.discord_hooks import Webhook

MODULE_NAME = "submit_modular"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/osu-submit-modular.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	#@sentry.captureTornado
	def asyncPost(self):
		newCharts = self.request.uri == "/web/osu-submit-modular-selector.php"
		try:
			# Resend the score in case of unhandled exceptions
			keepSending = True

			# Get request ip
			ip = self.getRequestIP()

			# Print arguments
			if glob.debug:
				requestsManager.printArguments(self)

			# Check arguments
			if not requestsManager.checkArguments(self.request.arguments, ["score", "iv", "pass"]):
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# TODO: Maintenance check

			# Get parameters and IP
			scoreDataEnc = self.get_argument("score")
			iv = self.get_argument("iv")
			password = self.get_argument("pass")
			ip = self.getRequestIP()

			# Get bmk and bml (notepad hack check)
			if "bmk" in self.request.arguments and "bml" in self.request.arguments:
				bmk = self.get_argument("bmk")
				bml = self.get_argument("bml")
			else:
				bmk = None
				bml = None

			# Get right AES Key
			if "osuver" in self.request.arguments:
				aeskey = "osu!-scoreburgr---------{}".format(self.get_argument("osuver"))
			else:
				aeskey = "h89f2-890h2h89b34g-h80g134n90133"

			# Get score data
			log.debug("Decrypting score data...")
			scoreData = aeshelper.decryptRinjdael(aeskey, iv, scoreDataEnc, True).split(":")
			username = scoreData[1].strip()

			# Login and ban check
			userID = userUtils.getID(username)
			# User exists check
			if userID == 0:
				raise exceptions.loginFailedException(MODULE_NAME, userID)
			# Bancho session/username-pass combo check
			if not userUtils.checkLogin(userID, password, ip):
				raise exceptions.loginFailedException(MODULE_NAME, username)
			# 2FA Check
			if userUtils.check2FA(userID, ip):
				raise exceptions.need2FAException(MODULE_NAME, userID, ip)
			# Generic bancho session check
			#if not userUtils.checkBanchoSession(userID):
				# TODO: Ban (see except exceptions.noBanchoSessionException block)
			#	raise exceptions.noBanchoSessionException(MODULE_NAME, username, ip)
			# Ban check
			if userUtils.isBanned(userID):
				raise exceptions.userBannedException(MODULE_NAME, username)
			# Data length check
			if len(scoreData) < 16:
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Get restricted
			restricted = userUtils.isRestricted(userID)

			# Create score object and set its data
			log.info("{} has submitted a score on {}...".format(username, scoreData[0]))
			s = score.score()
			oldStats = userUtils.getUserStats(userID, s.gameMode)
			s.setDataFromScoreData(scoreData)
			

			# Set score stuff missing in score data
			s.playerUserID = userID

			# Get beatmap info
			beatmapInfo = beatmap.beatmap()
			beatmapInfo.setDataFromDB(s.fileMd5)

			# Make sure the beatmap is submitted and updated
			if beatmapInfo.rankedStatus == rankedStatuses.NOT_SUBMITTED or beatmapInfo.rankedStatus == rankedStatuses.NEED_UPDATE or beatmapInfo.rankedStatus == rankedStatuses.UNKNOWN:
				log.debug("Beatmap is not submitted/outdated/unknown. Score submission aborted.")
				return

			"""
			Check FL rule (std only.)
			User sends score -> the submit handler checks for FL rule breakage -> 
			if break: block submission, send warning (log and players.)
			if not: allow submission.
			"""
			if (s.gameMode < 1): # Checks to see if the score is not standard.
				# Check play to see if it has been done on Bancho. Unfinished.
				# Remove DT or HT from Mods when checking if the play is done on Bancho
				# dthtcheck = s.mods
				# if ((s.mods & mods.FLASHLIGHT & mods.FLASHLIGHT) > 0):
				#	dthtcheck -= 64
				# if ((s.mods & mods.HALFTIME & mods.FLASHLIGHT) > 0):
				#	dthtcheck -=256

				# Request scores from osuapi for allow fl check.
				# flreq = requests.get("https://osu.ppy.sh/api/get_scores?b={}&limit=1&mods={}&k={}").format(beatmapInfo.beatmapID, dthtcheck, glob.conf.config["osuapi"]["apikey"])
				# fldata = json.loads(flreq)
				# flenable = fldata["enabled_mods"]

				# Fokabot msg variables to warn the user of rule breakage.
				flmsg = "Baka! {}, you have violated the FL rule! You tried to play a map that is 7.0*+ and is longer than 30 seconds. All scores that violate this rule will not be submitted. I hate wasting my time on stupid people who forget to turn their FL modifier off! >_>".format(username.encode().decode("ASCII", "ignore"))
				flmsgparams = urlencode({"k": glob.conf.config["server"]["apikey"], "to": username, "msg": flmsg})

				# Star and Mod calculation
				sresp = requests.get("http://127.0.0.1:5002/api/v1/pp?b={}&m={}".format(beatmapInfo.beatmapID, s.mods), timeout=10).text # gets beatmap stats with the added mods in json.
				sdata = json.loads(sresp) # loads beatmap info json
				stars = sdata["stars"] # looks for star rating in the array, returns # of stars with the added mods.
				mapLength = beatmapInfo.hitLength
				if ((s.mods & mods.DOUBLETIME) > 0):
					mapLength /= 1.5 # One thing to point out make sure you use division here, not multiplication :facepalm:
				if ((s.mods & mods.HALFTIME) > 0):
					mapLength /= 0.75

				# Actual rule check
				dbflcheck = glob.db.fetch("SELECT allow_fl FROM beatmaps WHERE beatmap_id = {} LIMIT 1".format(beatmapInfo.beatmapID))
				if (((s.mods & mods.FLASHLIGHT) > 0) and (dbflcheck["allow_fl"] == 1)): # Check if beatmap can bypass check, if so bypass, if not continue to check.
					pass
				elif (((s.mods & mods.FLASHLIGHT) > 0 and (stars > 7.0 and mapLength > 30 or stars > 8.0))):
					log.info("{} tried to submit a score with FL, but it broke the FL rule.".format(username))
					log.info("User: {}, Map MD5: {}, Length: {}, Stars: {}".format(username, scoreData[0], mapLength, stars))
					requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], flmsgparams))
					return
			else:
				pass # Passes the score if the score is not played in standard.

			# Calculate PP
			# NOTE: PP are std and mania only
			ppCalcException = None
			try:
				s.calculatePP()
			except Exception as e:
				# Intercept ALL exceptions and bypass them.
				# We want to save scores even in case PP calc fails
				# due to some rippoppai bugs.
				# I know this is bad, but who cares since I'll rewrite
				# the scores server again.
				log.error("Caught an exception in pp calculation, re-raising after saving score in db")
				s.pp = 0
				ppCalcException = e

			if beatmapInfo.rankedStatus >= rankedStatuses.LOVED and s.passed:
				s.pp = 0

			# Restrict obvious cheaters (LOL Welcome to Atoka, home of cheaters. 10k pp limit set.)
			if (s.pp >= 10000 and s.gameMode == gameModes.STD) and restricted == False:
				userUtils.restrict(userID)
				userUtils.appendNotes(userID, "Restricted due to too high pp gain ({}pp)".format(s.pp))
				log.warning("**{}** ({}) has been restricted due to too high pp gain **({}pp)**".format(username, userID, s.pp), "cm")

			# Check notepad hack
			if bmk is None and bml is None:
				# No bmk and bml params passed, edited or super old client
				#log.warning("{} ({}) most likely submitted a score from an edited client or a super old client".format(username, userID), "cm")
				pass
			elif bmk != bml and restricted == False:
				# bmk and bml passed and they are different, restrict the user
				userUtils.restrict(userID)
				userUtils.appendNotes(userID, "Restricted due to notepad hack")
				log.warning("**{}** ({}) has been restricted due to notepad hack".format(username, userID), "cm")
				return

			# Right before submitting the score, get the personal best score object (we need it for charts)
			if s.passed and s.oldPersonalBest > 0:
				oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
				if oldPersonalBestRank == 0:
					oldScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
					oldScoreboard.setPersonalBestRank()
					oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
				oldPersonalBest = score.score(s.oldPersonalBest, oldPersonalBestRank)
			else:
				oldPersonalBestRank = 0
				oldPersonalBest = None

			# Save score in db
			s.saveScoreInDB()

			# Client anti-cheat flags
			'''ignoreFlags = 4
			if glob.debug == True:
				# ignore multiple client flags if we are in debug mode
				ignoreFlags |= 8
			haxFlags = (len(scoreData[17])-len(scoreData[17].strip())) & ~ignoreFlags
			if haxFlags != 0 and restricted == False:
				userHelper.restrict(userID)
				userHelper.appendNotes(userID, "-- Restricted due to clientside anti cheat flag ({}) (cheated score id: {})".format(haxFlags, s.scoreID))
				log.warning("**{}** ({}) has been restricted due clientside anti cheat flag **({})**".format(username, userID, haxFlags), "cm")'''

			# Mi stavo preparando per scendere
			# Mi stavo preparando per comprare i dolci
			# Oggi e' il compleanno di mio nipote
			# Dovevamo festeggiare staseraaaa
			# ----
			# Da un momento all'altro ho sentito una signora
			# Correte, correte se ne e' sceso un muro
			# Da un momento all'altro ho sentito una signora
			# Correte, correte se ne e' sceso un muro
			# --- (io sto angora in ganottier ecche qua) ---
			# Sono scesa e ho visto ilpalazzochesenee'caduto
			# Ho preso a mio cognato, che stava svenuto
			# Mia figlia e' scesa, mia figlia ha urlato
			# "C'e' qualcuno sotto, C'e' qualcuno sotto"
			# "C'e' qualcuno sotto, C'e' qualcuno sottoooooooooo"
			# --- (scusatm che sto angor emozzionat non parlo ancora moltobbene) ---
			# Da un momento all'altro ho sentito una signora
			# Correte, correte se ne e' sceso un muro
			# Da un momento all'altro ho sentito una signora
			# Correte, correte se ne e' sceso un muro
			# -- THIS IS THE PART WITH THE GOOD SOLO (cit <3) --
			# Vedete quel palazzo la' vicino
			# Se ne sta scendendo un po' alla volta
			# Piano piano, devono prendere provvedimenti
			# Al centro qua hanno fatto una bella ristrututuitriazione
			# Hanno mess le panghina le fondane iffiori
			# LALALALALALALALALA
			if s.score < 0 or s.score > (2 ** 63) - 1:
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Banned due to negative score (score submitter)")

			# Make sure the score is not memed
			if s.gameMode == gameModes.MANIA and s.score > 1000000:
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Banned due to mania score > 1000000 (score submitter)")

			# Ci metto la faccia, ci metto la testa e ci metto il mio cuore
			if ((s.mods & mods.DOUBLETIME) > 0 and (s.mods & mods.HALFTIME) > 0) \
					or ((s.mods & mods.HARDROCK) > 0 and (s.mods & mods.EASY) > 0)\
					or ((s.mods & mods.SUDDENDEATH) > 0 and (s.mods & mods.NOFAIL) > 0):
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Impossible mod combination {} (score submitter)".format(s.mods))

#			if s.completed == 3:
#				print("I want caking!")
#				butterCake.bake(self, s)

			"""
			# Make sure process list has been passed
			if s.completed == 3 and "pl" not in self.request.arguments and not restricted:
				userUtils.restrict(userID)
				userUtils.appendNotes(userID, "Restricted due to missing process list while submitting a score (most likely he used a score submitter)")
				log.warning("**{}** ({}) has been restricted due to missing process list".format(username, userID), "cm")
			"""

			

			""" Bake a cake

			if s.passed == True:
					butterCake.bake(self, s)
			"""

			# Save replay
			if s.passed and s.scoreID > 0 and s.completed == 3:
				if "score" in self.request.files:
					# Save the replay if it was provided
					log.debug("Saving replay ({})...".format(s.scoreID))
					replay = self.request.files["score"][0]["body"]
					with open(".data/replays/replay_{}.osr".format(s.scoreID), "wb") as f:
						f.write(replay)
				else:
					# Restrict if no replay was provided
					if not restricted:
						userUtils.restrict(userID)
						userUtils.appendNotes(userID, "Restricted due to missing replay while submitting a score.")
						log.warning("**{}** ({}) has been restricted due to not submitting a replay on map {}.".format(
							username, userID, s.fileMd5
						), "cm")

			# Make sure the replay has been saved (debug)
			if not os.path.isfile(".data/replays/replay_{}.osr".format(s.scoreID)) and s.completed == 3:
				log.error("Replay for score {} not saved!!".format(s.scoreID), "bunker")

			# Let the api know of this score
			if s.scoreID:
				glob.redis.publish("api:score_submission", s.scoreID)

			# Re-raise pp calc exception after saving score, cake, replay etc
			# so Sentry can track it without breaking score submission
			if ppCalcException is not None:
				raise ppCalcException

			# If there was no exception, update stats and build score submitted panel
			# We don't have to do that since stats are recalculated with the cron
			# Update beatmap playcount (and passcount)
			beatmap.incrementPlaycount(s.fileMd5, s.passed)

			# Get "before" stats for ranking panel (only if passed)
			if s.passed:
				# Get stats and rank
				oldUserData = glob.userStatsCache.get(userID, s.gameMode)
				oldRank = userUtils.getGameRank(userID, s.gameMode)

				# Try to get oldPersonalBestRank from cache
				oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
				if oldPersonalBestRank == 0:
					# oldPersonalBestRank not found in cache, get it from db
					oldScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
					oldScoreboard.setPersonalBest()
					oldPersonalBestRank = oldScoreboard.personalBestRank if oldScoreboard.personalBestRank > 0 else 0

			# Always update users stats (total/ranked score, playcount, level, acc and pp)
			# even if not passed
			log.info("Updating {}'s stats...".format(username))
			userUtils.updateStats(userID, s)

			# Get "after" stats for ranking panel
			# and to determine if we should update the leaderboard
			# (only if we passed that song)
			if s.passed:
				maxCombo = userUtils.getMaxCombo(userID, s.gameMode) 
				# Get new stats
				newUserData = userUtils.getUserStats(userID, s.gameMode)
				glob.userStatsCache.update(userID, s.gameMode, newUserData)

				# Update leaderboard (global and country) if score/pp has changed
				if s.completed == 3 and newUserData["pp"] != oldUserData["pp"]:
					leaderboardHelper.update(userID, newUserData["pp"], s.gameMode)
					leaderboardHelper.updateCountry(userID, newUserData["pp"], s.gameMode)

			# TODO: Update total hits and max combo
			# Update latest activity
			userUtils.updateLatestActivity(userID)

			# IP log
			userUtils.IPLog(userID, ip)

			# Score submission and stats update done
			log.debug("Score submission and user stats update done!")

			# Score has been submitted, do not retry sending the score if
			# there are exceptions while building the ranking panel
			keepSending = False

			# At the end, check achievements
			if s.passed:
				new_achievements = secret.achievements.utils.unlock_achievements(s, beatmapInfo, newUserData)

			# Output ranking panel only if we passed the song
			# and we got valid beatmap info from db
			if beatmapInfo is not None and beatmapInfo != False and s.passed:
				log.debug("Started building ranking panel")

				# Trigger bancho stats cache update
				glob.redis.publish("peppy:update_cached_stats", userID)
				newScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
				newScoreboard.setPersonalBestRank()
				personalBestID = newScoreboard.getPersonalBestID()
				assert personalBestID is not None
				currentPersonalBest = score.score(personalBestID, newScoreboard.personalBestRank)
					
				# Get rank info (current rank, pp/score to next rank, user who is 1 rank above us)
				rankInfo = leaderboardHelper.getRankInfo(userID, s.gameMode)

				if newCharts:
					log.debug("Using new charts")
					dicts = [
						collections.OrderedDict([
							("beatmapId", beatmapInfo.beatmapID),
							("beatmapSetId", beatmapInfo.beatmapSetID),
							("beatmapPlaycount", beatmapInfo.playcount + 1),
							("beatmapPasscount", beatmapInfo.passcount + (s.completed == 3)),
							("approvedDate", "")
						]),
						BeatmapChart(
							oldPersonalBest if s.completed == 3 else currentPersonalBest,
							currentPersonalBest if s.completed == 3 else s,
							beatmapInfo.beatmapID,
						),
						OverallChart(
							userID, oldUserData, newUserData, maxCombo, s, new_achievements, oldRank, rankInfo["currentRank"]
						)
					]
				else:
					log.debug("Using old charts")
					dicts = [
						collections.OrderedDict([
							("beatmapId", beatmapInfo.beatmapID),
							("beatmapSetId", beatmapInfo.beatmapSetID),
							("beatmapPlaycount", beatmapInfo.playcount),
							("beatmapPasscount", beatmapInfo.passcount),
							("approvedDate", "")
						]),
						collections.OrderedDict([
							("chartId", "overall"),
							("chartName", "Overall Ranking"),
							("chartEndDate", ""),
							("beatmapRankingBefore", oldPersonalBestRank),
							("beatmapRankingAfter", newScoreboard.personalBestRank),
							("rankedScoreBefore", oldUserData["rankedScore"]),
							("rankedScoreAfter", newUserData["rankedScore"]),
							("totalScoreBefore", oldUserData["totalScore"]),
							("totalScoreAfter", newUserData["totalScore"]),
							("playCountBefore", newUserData["playcount"]),
							("accuracyBefore", float(oldUserData["accuracy"]) / 100),
							("accuracyAfter", float(newUserData["accuracy"]) / 100),
							("rankBefore", oldRank),
							("rankAfter", rankInfo["currentRank"]),
							("toNextRank", rankInfo["difference"]),
							("toNextRankUser", rankInfo["nextUsername"]),
							("achievements", ""),
							("achievements-new", secret.achievements.utils.achievements_response(new_achievements)),
							("onlineScoreId", s.scoreID)
						])
					]
				output = "\n".join(zingonify(x) for x in dicts)

				# Some debug messages
				log.debug("Generated output for online ranking screen!")
				log.debug(output)
				
				userStats = userUtils.getUserStats(userID, s.gameMode)
				if s.completed == 3 and restricted == False and beatmapInfo.rankedStatus >= rankedStatuses.RANKED and s.pp > 0:
					glob.redis.publish("scores:new_score", json.dumps({
					"gm":s.gameMode,
					"user":{"username":username, "userID": userID, "rank":newUserData["gameRank"],"oldaccuracy":oldStats["accuracy"],"accuracy":newUserData["accuracy"], "oldpp":oldStats["pp"],"pp":newUserData["pp"]},
					"score":{"scoreID": s.scoreID, "mods":s.mods, "accuracy":s.accuracy, "missess":s.cMiss, "combo":s.maxCombo, "pp":s.pp, "rank":newScoreboard.personalBestRank, "ranking":s.rank},
					"beatmap":{"beatmapID": beatmapInfo.beatmapID, "beatmapSetID": beatmapInfo.beatmapSetID, "max_combo":beatmapInfo.maxCombo, "song_name":beatmapInfo.songName}
					}))

				# send message to #announce if we're rank #1
				if newScoreboard.personalBestRank == 1 and s.completed == 3 and restricted == False:
					annmsg = "[https://atoka.pw/?u={} {}] achieved rank #1 on [https://osu.ppy.sh/b/{} {}] ({})".format(
						userID,
						username.encode().decode("ASCII", "ignore"),
						beatmapInfo.beatmapID,
						beatmapInfo.songName.encode().decode("ASCII", "ignore"),
						gameModes.getGamemodeFull(s.gameMode)
					)
					params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": "#announce", "msg": annmsg})
					requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))

					# upon new #1 = send the score to the discord bot
					# s=0 = regular && s=1 = relax
					ppGained = newUserData["pp"] - oldUserData["pp"]
					gainedRanks = oldRank - rankInfo["currentRank"]
					# webhook to discord

					#TEMPORARY mods handle
					ScoreMods = ""
					
					if s.mods == 0:
						ScoreMods += "nomod"
					if s.mods & mods.NOFAIL > 0:
						ScoreMods += "NF"
					if s.mods & mods.EASY > 0:
						ScoreMods += "EZ"
					if s.mods & mods.HIDDEN > 0:
						ScoreMods += "HD"
					if s.mods & mods.HARDROCK > 0:
						ScoreMods += "HR"
					if s.mods & mods.DOUBLETIME > 0:
						ScoreMods += "DT"
					if s.mods & mods.HALFTIME > 0:
						ScoreMods += "HT"
					if s.mods & mods.FLASHLIGHT > 0:
						ScoreMods += "FL"
					if s.mods & mods.SPUNOUT > 0:
						ScoreMods += "SO"
					if s.mods & mods.TOUCHSCREEN > 0:
						ScoreMods += "TD"
					if s.mods & mods.RELAX > 0:
						ScoreMods += "RX"
					if s.mods & mods.RELAX2 > 0:
						ScoreMods += "AP"


					url = glob.conf.config["discord"]["webhook"]
				
					embed = Webhook(url, color=0x35b75c)
					embed.set_author(name=username.encode().decode("ASCII", "ignore"), icon='https://i.imgur.com/rdm3W9t.png')
					embed.set_desc("Achieved #1 on mode **{}**, {} +{}!".format(gameModes.getGamemodeFull(s.gameMode), beatmapInfo.songName.encode().decode("ASCII", "ignore"), ScoreMods))
					embed.add_field(name='Total: {}pp'.format(float("{0:.2f}".format(s.pp))), value='Gained: +{}pp'.format(float("{0:.2f}".format(ppGained))))
					embed.add_field(name='Actual rank: {}'.format(rankInfo["currentRank"]), value='[Download Link](http://storage.ripple.moe/d/{})'.format(beatmapInfo.beatmapSetID))
					embed.set_image('https://assets.ppy.sh/beatmaps/{}/covers/cover.jpg'.format(beatmapInfo.beatmapSetID))
					embed.post()

				# Write message to client
				self.write(msg)
			else:
				# No ranking panel, send just "ok"
				self.write("ok")

			# Send username change request to bancho if needed
			# (key is deleted bancho-side)
			newUsername = glob.redis.get("ripple:change_username_pending:{}".format(userID))
			if newUsername is not None:
				log.debug("Sending username change request for user {} to Bancho".format(userID))
				glob.redis.publish("peppy:change_username", json.dumps({
					"userID": userID,
					"newUsername": newUsername.decode("utf-8")
				}))

			# Datadog stats
			glob.dog.increment(glob.DATADOG_PREFIX+".submitted_scores")
		except exceptions.invalidArgumentsException:
			pass
		except exceptions.loginFailedException:
			self.write("error: pass")
		except exceptions.need2FAException:
			# Send error pass to notify the user
			# resend the score at regular intervals
			# for users with memy connection
			self.set_status(408)
			self.write("error: 2fa")
		except exceptions.userBannedException:
			self.write("error: ban")
		except exceptions.noBanchoSessionException:
			# We don't have an active bancho session.
			# Don't ban the user but tell the client to send the score again.
			# Once we are sure that this error doesn't get triggered when it
			# shouldn't (eg: bancho restart), we'll ban users that submit
			# scores without an active bancho session.
			# We only log through schiavo atm (see exceptions.py).
			self.set_status(408)
			self.write("error: pass")
		except:
			# Try except block to avoid more errors
			try:
				log.error("Unknown error in {}!\n```{}\n{}```".format(MODULE_NAME, sys.exc_info(), traceback.format_exc()))
				if glob.sentry:
					yield tornado.gen.Task(self.captureException, exc_info=True)
			except:
				pass

			# Every other exception returns a 408 error (timeout)
			# This avoids lost scores due to score server crash
			# because the client will send the score again after some time.
			if keepSending:
				self.set_status(408)
