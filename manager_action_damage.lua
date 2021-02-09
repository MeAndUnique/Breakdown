function applyDamage(rSource, rTarget, bSecret, sDamage, nTotal)
	local nodeTargetCT = ActorManager.getCTNode(rTarget);

	-- Get health fields
	local rDamageValues = getDamageValues(rTarget, nodeTargetCT);
	if not rDamageValues then
		return;
	end

	rDamageValues.nTotal = nTotal;
	rDamageValues.nConcentrationDamage = 0;

	-- Prepare for notifications
	local aNotifications = {};
	local bRemoveTarget = false;

	-- Remember current health status
	local sOriginalStatus = ActorHealthManager.getHealthStatus(rTarget);

	-- Decode damage/heal description
	local rDamageOutput = decodeDamageText(nTotal, sDamage);
	
	-- Healing
	if rDamageOutput.sType == "recovery" then
		handleRecovery(rTarget, rDamageValues, aNotifications, rDamageOutput);

	-- Healing
	elseif rDamageOutput.sType == "heal" then
		handleHealing(rTarget, rDamageValues, aNotifications, rDamageOutput);

	-- Temporary hit points
	elseif rDamageOutput.sType == "temphp" then
		rDamageValues.nTempHP = math.max(rDamageValues.nTempHP, nTotal);

	-- Damage
	else
		handleDamage(rSource, rTarget, sDamage, rDamageValues, aNotifications, rDamageOutput);
	end
	
	-- Clear death saves if health greater than zero
	if rDamageValues.nWounds < rDamageValues.nTotalHP then
		handleHasHealth(rTarget, rDamageValues)
	else
		handleMaximumWounds(rTarget, rDamageValues);
	end

	-- Set health fields
	setHealthFields(rTarget, nodeTargetCT, rDamageValues);

	-- Check for status change
	checkStatusChange(rTarget, aNotifications)
	
	-- Output results
	messageDamage(rSource, rTarget, bSecret, rDamageOutput.sTypeOutput, sDamage, rDamageOutput.sVal, table.concat(aNotifications, " "));

	-- Remove target after applying damage
	if bRemoveTarget and rSource and rTarget then
		TargetingManager.removeTarget(ActorManager.getCTNodeName(rSource), ActorManager.getCTNodeName(rTarget));
	end

	-- Check for required concentration checks
	checkConcentration(rTarget, rDamageValues)

	if postProcessDamage then
		postprocessDamage(rSource, rTarget, rDamageValues, rDamageOutput);
	end
end

function getDamageValues(rTarget, nodeTargetCT)
	local rDamageValues = {};
	if nodeTargetCT then
		rDamageValues.nTotalHP = DB.getValue(nodeTargetCT, "hptotal", 0);
		rDamageValues.nTempHP = DB.getValue(nodeTargetCT, "hptemp", 0);
		rDamageValues.nWounds = DB.getValue(nodeTargetCT, "wounds", 0);
		rDamageValues.nDeathSaveSuccess = DB.getValue(nodeTargetCT, "deathsavesuccess", 0);
		rDamageValues.nDeathSaveFail = DB.getValue(nodeTargetCT, "deathsavefail", 0);
	elseif ActorManager.isPC(rTarget) then
		local nodeTargetPC = ActorManager.getCreatureNode(rTarget);
		rDamageValues.nTotalHP = DB.getValue(nodeTargetPC, "hp.total", 0);
		rDamageValues.nTempHP = DB.getValue(nodeTargetPC, "hp.temporary", 0);
		rDamageValues.nWounds = DB.getValue(nodeTargetPC, "hp.wounds", 0);
		rDamageValues.nDeathSaveSuccess = DB.getValue(nodeTargetPC, "hp.deathsavesuccess", 0);
		rDamageValues.nDeathSaveFail = DB.getValue(nodeTargetPC, "hp.deathsavefail", 0);
	else
		return;
	end
	return rDamageValues;
end

function handleRecovery(rTarget, rDamageValues, aNotifications, rDamageOutput)
	local sClassNode = string.match(sDamage, "%[NODE:([^]]+)%]");
	
	if rDamageValues.nWounds <= 0 then
		table.insert(aNotifications, "[NOT WOUNDED]");
	else
		-- Determine whether HD available
		local nClassHD = 0;
		local nClassHDMult = 0;
		local nClassHDUsed = 0;
		if ActorManager.isPC(rTarget) and sClassNode then
			local nodeClass = DB.findNode(sClassNode);
			nClassHD = DB.getValue(nodeClass, "level", 0);
			nClassHDMult = #(DB.getValue(nodeClass, "hddie", {}));
			nClassHDUsed = DB.getValue(nodeClass, "hdused", 0);
		end
		
		if (nClassHD * nClassHDMult) <= nClassHDUsed then
			table.insert(aNotifications, "[INSUFFICIENT HIT DICE FOR THIS CLASS]");
		else
			handleHealing(rTarget, rDamageValues, aNotifications, rDamageOutput);
			
			-- Decrement HD used
			if ActorManager.isPC(rTarget) and sClassNode then
				local nodeClass = DB.findNode(sClassNode);
				DB.setValue(nodeClass, "hdused", "number", nClassHDUsed + 1);
				rDamageOutput.sVal = rDamageOutput.sVal .. "][HD-1";
			end
		end
	end
end

function handleHealing(rTarget, rDamageValues, aNotifications, rDamageOutput)
	if rDamageValues.nWounds <= 0 then
		table.insert(aNotifications, "[NOT WOUNDED]");
	else
		-- Calculate heal amounts
		local nHealAmount = rDamageOutput.nVal;
		
		-- If healing from zero (or negative), then remove Stable effect and reset wounds to match HP
		if (nHealAmount > 0) and (rDamageValues.nWounds >= rDamageValues.nTotalHP) then
			EffectManager.removeEffect(ActorManager.getCTNode(rTarget), "Stable");
			rDamageValues.nWounds = rDamageValues.nTotalHP;
		end
		
		local nWoundHealAmount = math.min(nHealAmount, rDamageValues.nWounds);
		rDamageValues.nWounds = rDamageValues.nWounds - nWoundHealAmount;
		
		-- Display actual heal amount
		rDamageOutput.nVal = nWoundHealAmount;
		rDamageOutput.sVal = string.format("%01d", nWoundHealAmount);
	end
end

function handleDamage(rSource, rTarget, sDamage, rDamageValues, aNotifications, rDamageOutput)
	-- Apply any targeted damage effects 
	-- NOTE: Dice determined randomly, instead of rolled
	applyTargetDamageEffects(rSource, rTarget, sDamage, rDamageValues, aNotifications, rDamageOutput);
	
	-- Handle avoidance/evasion and half damage
	handleAvoidance(rSource, rTarget, sDamage, rDamageValues, aNotifications, rDamageOutput);
	
	-- Apply damage type adjustments
	applyAdjustments(rSource, rTarget, rDamageValues, aNotifications, rDamageOutput);
	
	-- Prepare for concentration checks if damaged
	rDamageValues.nConcentrationDamage = rDamageValues.nAdjustedDamage;
	
	-- Reduce damage by temporary hit points
	handleTemporaryHitPoints(rDamageValues, aNotifications)

	-- Apply remaining damage
	applyAdjustedDamage(rTarget, rDamageValues, aNotifications, rDamageOutput);
	
	-- Update the damage output variable to reflect adjustments
	rDamageOutput.nVal = rDamageValues.nAdjustedDamage;
	rDamageOutput.sVal = string.format("%01d", rDamageValues.nAdjustedDamage);
end

function applyTargetDamageEffects(rSource, rTarget, sDamage, rDamageValues, aNotifications, rDamageOutput)
	if rSource and rTarget and rTarget.nOrder then
		local bCritical = string.match(sDamage, "%[CRITICAL%]");
		local aTargetedDamage = EffectManager5E.getEffectsBonusByType(rSource, {"DMG"}, true, rDamageOutput.aDamageFilter, rTarget, true);

		local nDamageEffectTotal = 0;
		local nDamageEffectCount = 0;
		for k, v in pairs(aTargetedDamage) do
			local bValid = true;
			local aSplitByDmgType = StringManager.split(k, ",", true);
			for _,vDmgType in ipairs(aSplitByDmgType) do
				if vDmgType == "critical" and not bCritical then
					bValid = false;
				end
			end
			
			if bValid then
				local nSubTotal = StringManager.evalDice(v.dice, v.mod);
				
				local sDamageType = rDamageOutput.sFirstDamageType;
				if sDamageType then
					sDamageType = sDamageType .. "," .. k;
				else
					sDamageType = k;
				end

				rDamageOutput.aDamageTypes[sDamageType] = (rDamageOutput.aDamageTypes[sDamageType] or 0) + nSubTotal;
				
				nDamageEffectTotal = nDamageEffectTotal + nSubTotal;
				nDamageEffectCount = nDamageEffectCount + 1;
			end
		end
		rDamageValues.nTotal = rDamageValues.nTotal + nDamageEffectTotal;

		if nDamageEffectCount > 0 then
			if nDamageEffectTotal ~= 0 then
				local sFormat = "[" .. Interface.getString("effects_tag") .. " %+d]";
				table.insert(aNotifications, string.format(sFormat, nDamageEffectTotal));
			else
				table.insert(aNotifications, "[" .. Interface.getString("effects_tag") .. "]");
			end
		end
	end
end

function handleAvoidance(rSource, rTarget, sDamage, rDamageValues, aNotifications, rDamageOutput)
	local isAvoided = false;
	local isHalf = string.match(sDamage, "%[HALF%]");
	local sAttack = string.match(sDamage, "%[DAMAGE[^]]*%] ([^[]+)");
	if sAttack then
		local sDamageState = getDamageState(rSource, rTarget, StringManager.trim(sAttack));
		if sDamageState == "none" then
			isAvoided = true;
			bRemoveTarget = true;
		elseif sDamageState == "half_success" then
			isHalf = true;
			bRemoveTarget = true;
		elseif sDamageState == "half_failure" then
			isHalf = true;
		end
	end
	if isAvoided then
		table.insert(aNotifications, "[EVADED]");
		for kType, nType in pairs(rDamageOutput.aDamageTypes) do
			rDamageOutput.aDamageTypes[kType] = 0;
		end
		nTotal = 0;
	elseif isHalf then
		table.insert(aNotifications, "[HALF]");
		local bCarry = false;
		for kType, nType in pairs(rDamageOutput.aDamageTypes) do
			local nOddCheck = nType % 2;
			rDamageOutput.aDamageTypes[kType] = math.floor(nType / 2);
			if nOddCheck == 1 then
				if bCarry then
					rDamageOutput.aDamageTypes[kType] = rDamageOutput.aDamageTypes[kType] + 1;
					bCarry = false;
				else
					bCarry = true;
				end
			end
		end
		rDamageValues.nTotal = math.max(math.floor(rDamageValues.nTotal / 2), 1);
	end
end

function applyAdjustments(rSource, rTarget, rDamageValues, aNotifications, rDamageOutput)
	local nDamageAdjust, bVulnerable, bResist = getDamageAdjust(rSource, rTarget, rDamageValues.nTotal, rDamageOutput);
	rDamageValues.nAdjustedDamage = rDamageValues.nTotal + nDamageAdjust;
	if rDamageValues.nAdjustedDamage < 0 then
		rDamageValues.nAdjustedDamage = 0;
	end
	if bResist then
		if rDamageValues.nAdjustedDamage <= 0 then
			table.insert(aNotifications, "[RESISTED]");
		else
			table.insert(aNotifications, "[PARTIALLY RESISTED]");
		end
	end
	if bVulnerable then
		table.insert(aNotifications, "[VULNERABLE]");
	end
end

function handleTemporaryHitPoints(rDamageValues, aNotifications)
	if rDamageValues.nTempHP > 0 and rDamageValues.nAdjustedDamage > 0 then
		if rDamageValues.nAdjustedDamage > rDamageValues.nTempHP then
			rDamageValues.nAdjustedDamage = rDamageValues.nAdjustedDamage - rDamageValues.nTempHP;
			rDamageValues.nTempHP = 0;
			table.insert(aNotifications, "[PARTIALLY ABSORBED]");
		else
			rDamageValues.nTempHP = rDamageValues.nTempHP - rDamageValues.nAdjustedDamage;
			rDamageValues.nAdjustedDamage = 0;
			table.insert(aNotifications, "[ABSORBED]");
		end
	end
end

function applyAdjustedDamage(rTarget, rDamageValues, aNotifications, rDamageOutput)
	if rDamageValues.nAdjustedDamage > 0 then
		-- Remember previous wounds
		local nPrevWounds = rDamageValues.nWounds;
		
		-- Apply wounds
		rDamageValues.nWounds = math.max(rDamageValues.nWounds + rDamageValues.nAdjustedDamage, 0);
		
		-- Calculate wounds above HP
		local nRemainder = 0;
		if rDamageValues.nWounds > rDamageValues.nTotalHP then
			nRemainder = rDamageValues.nWounds - rDamageValues.nTotalHP;
			rDamageValues.nWounds = rDamageValues.nTotalHP;
		end
		
		-- Prepare for calcs
		local nodeTargetCT = ActorManager.getCTNode(rTarget);

		-- Deal with remainder damage
		handleRemainderDamage(rTarget, nRemainder, nPrevWounds, rDamageValues, aNotifications, rDamageOutput)
		
		-- Handle stable situation
		EffectManager.removeEffect(nodeTargetCT, "Stable");
		
		-- Disable regeneration next round on correct damage type
		disableRegeneration(nodeTargetCT, rDamageOutput)
	end
end

function handleRemainderDamage(rTarget, nRemainder, nPrevWounds, rDamageValues, aNotifications, rDamageOutput)
	if nRemainder >= rDamageValues.nTotalHP then
		table.insert(aNotifications, "[INSTANT DEATH]");
		rDamageValues.nDeathSaveFail = 3;
	elseif nRemainder > 0 then
		table.insert(aNotifications, "[DAMAGE EXCEEDS HIT POINTS BY " .. nRemainder.. "]");
		if nPrevWounds >= rDamageValues.nTotalHP then
			if rDamageOutput.bCritical then
				rDamageValues.nDeathSaveFail = rDamageValues.nDeathSaveFail + 2;
			else
				rDamageValues.nDeathSaveFail = rDamageValues.nDeathSaveFail + 1;
			end
		end
	else
		if OptionsManager.isOption("HRMD", "on") and (rDamageValues.nAdjustedDamage >= (rDamageValues.nTotalHP / 2)) then
			ActionSave.performSystemShockRoll(nil, rTarget);
		end
	end
end

function disableRegeneration(nodeTargetCT, rDamageOutput)
	if nodeTargetCT then
		-- Calculate which damage types actually did damage
		local aTempDamageTypes = {};
		local aActualDamageTypes = {};
		for k,v in pairs(rDamageOutput.aDamageTypes) do
			if v > 0 then
				table.insert(aTempDamageTypes, k);
			end
		end
		local aActualDamageTypes = StringManager.split(table.concat(aTempDamageTypes, ","), ",", true);
		
		-- Check target's effects for regeneration effects that match
		for _,v in pairs(DB.getChildren(nodeTargetCT, "effects")) do
			local nActive = DB.getValue(v, "isactive", 0);
			if (nActive == 1) then
				local bMatch = false;
				local sLabel = DB.getValue(v, "label", "");
				local aEffectComps = EffectManager.parseEffect(sLabel);
				for i = 1, #aEffectComps do
					local rEffectComp = EffectManager5E.parseEffectComp(aEffectComps[i]);
					if rEffectComp.type == "REGEN" then
						for _,v2 in pairs(rEffectComp.remainder) do
							if StringManager.contains(aActualDamageTypes, v2) then
								bMatch = true;
							end
						end
					end
					
					if bMatch then
						EffectManager.disableEffect(nodeTargetCT, v);
					end
				end
			end
		end
	end
end

function handleHasHealth(rTarget, rDamageValues)
	rDamageValues.nDeathSaveSuccess = 0;
	rDamageValues.nDeathSaveFail = 0;
	if EffectManager5E.hasEffect(rTarget, "Stable") then
		EffectManager.removeEffect(ActorManager.getCTNode(rTarget), "Stable");
	end
	if EffectManager5E.hasEffect(rTarget, "Unconscious") then
		EffectManager.removeEffect(ActorManager.getCTNode(rTarget), "Unconscious");
	end
end

function handleMaximumWounds(rTarget, rDamageValues)
	if not EffectManager5E.hasEffect(rTarget, "Unconscious") then
		EffectManager.addEffect("", "", ActorManager.getCTNode(rTarget), { sName = "Unconscious", nDuration = 0 }, true);
	end
end

function setHealthFields(rTarget, nodeTargetCT, rDamageValues)
	if nodeTargetCT then
		DB.setValue(nodeTargetCT, "deathsavesuccess", "number", math.min(rDamageValues.nDeathSaveSuccess, 3));
		DB.setValue(nodeTargetCT, "deathsavefail", "number", math.min(rDamageValues.nDeathSaveFail, 3));
		DB.setValue(nodeTargetCT, "hptemp", "number", rDamageValues.nTempHP);
		DB.setValue(nodeTargetCT, "wounds", "number", rDamageValues.nWounds);
	elseif ActorManager.isPC(rTarget) then
		local nodeTargetPC = ActorManager.getCreatureNode(rTarget);
		DB.setValue(nodeTargetPC, "hp.deathsavesuccess", "number", math.min(rDamageValues.nDeathSaveSuccess, 3));
		DB.setValue(nodeTargetPC, "hp.deathsavefail", "number", math.min(rDamageValues.nDeathSaveFail, 3));
		DB.setValue(nodeTargetPC, "hp.temporary", "number", rDamageValues.nTempHP);
		DB.setValue(nodeTargetPC, "hp.wounds", "number", rDamageValues.nWounds);
	end
end

function checkStatusChange(rTarget, aNotifications)
	local bShowStatus = false;
	if ActorManager.getFaction(rTarget) == "friend" then
		bShowStatus = not OptionsManager.isOption("SHPC", "off");
	else
		bShowStatus = not OptionsManager.isOption("SHNPC", "off");
	end
	if bShowStatus then
		local sNewStatus = ActorHealthManager.getHealthStatus(rTarget);
		if sOriginalStatus ~= sNewStatus then
			table.insert(aNotifications, "[" .. Interface.getString("combat_tag_status") .. ": " .. sNewStatus .. "]");
		end
	end
end

function checkConcentration(rTarget, rDamageValues)
	if rDamageValues.nConcentrationDamage > 0 and ActionSave.hasConcentrationEffects(rTarget) then
		if rDamageValues.nWounds < rDamageValues.nTotalHP then
			local nTargetDC = math.max(math.floor(rDamageValues.nConcentrationDamage / 2), 10);
			ActionSave.performConcentrationRoll(nil, rTarget, nTargetDC);
		else
			ActionSave.expireConcentrationEffects(rTarget);
		end
	end
end