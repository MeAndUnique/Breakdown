function applyDamage(rSource, rTarget, bSecret, sDamage, nTotal)
	local nodeTargetCT = ActorManager.getCTNode(rTarget);

	-- Get health fields
	local nTotalHP, nTempHP, nWounds, nDeathSaveSuccess, nDeathSaveFail;
	if nodeTargetCT then
		nTotalHP = DB.getValue(nodeTargetCT, "hptotal", 0);
		nTempHP = DB.getValue(nodeTargetCT, "hptemp", 0);
		nWounds = DB.getValue(nodeTargetCT, "wounds", 0);
		nDeathSaveSuccess = DB.getValue(nodeTargetCT, "deathsavesuccess", 0);
		nDeathSaveFail = DB.getValue(nodeTargetCT, "deathsavefail", 0);
	elseif ActorManager.isPC(rTarget) then
		local nodeTargetPC = ActorManager.getCreatureNode(rTarget);
		nTotalHP = DB.getValue(nodeTargetPC, "hp.total", 0);
		nTempHP = DB.getValue(nodeTargetPC, "hp.temporary", 0);
		nWounds = DB.getValue(nodeTargetPC, "hp.wounds", 0);
		nDeathSaveSuccess = DB.getValue(nodeTargetPC, "hp.deathsavesuccess", 0);
		nDeathSaveFail = DB.getValue(nodeTargetPC, "hp.deathsavefail", 0);
	else
		return;
	end

	-- Prepare for notifications
	local aNotifications = {};
	local nConcentrationDamage = 0;
	local bRemoveTarget = false;

	-- Remember current health status
	local sOriginalStatus = ActorHealthManager.getHealthStatus(rTarget);

	-- Decode damage/heal description
	local rDamageOutput = decodeDamageText(nTotal, sDamage);
	
	-- Healing
	if rDamageOutput.sType == "recovery" then
		local sClassNode = string.match(sDamage, "%[NODE:([^]]+)%]");
		
		if nWounds <= 0 then
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
				-- Calculate heal amounts
				local nHealAmount = rDamageOutput.nVal;
				
				-- If healing from zero (or negative), then remove Stable effect and reset wounds to match HP
				if (nHealAmount > 0) and (nWounds >= nTotalHP) then
					EffectManager.removeEffect(ActorManager.getCTNode(rTarget), "Stable");
					nWounds = nTotalHP;
				end
				
				local nWoundHealAmount = math.min(nHealAmount, nWounds);
				nWounds = nWounds - nWoundHealAmount;
				
				-- Display actual heal amount
				rDamageOutput.nVal = nWoundHealAmount;
				rDamageOutput.sVal = string.format("%01d", nWoundHealAmount);
				
				-- Decrement HD used
				if ActorManager.isPC(rTarget) and sClassNode then
					local nodeClass = DB.findNode(sClassNode);
					DB.setValue(nodeClass, "hdused", "number", nClassHDUsed + 1);
					rDamageOutput.sVal = rDamageOutput.sVal .. "][HD-1";
				end
			end
		end

	-- Healing
	elseif rDamageOutput.sType == "heal" then
		if nWounds <= 0 then
			table.insert(aNotifications, "[NOT WOUNDED]");
		else
			-- Calculate heal amounts
			local nHealAmount = rDamageOutput.nVal;
			
			-- If healing from zero (or negative), then remove Stable effect and reset wounds to match HP
			if (nHealAmount > 0) and (nWounds >= nTotalHP) then
				EffectManager.removeEffect(ActorManager.getCTNode(rTarget), "Stable");
				nWounds = nTotalHP;
			end
			
			local nWoundHealAmount = math.min(nHealAmount, nWounds);
			nWounds = nWounds - nWoundHealAmount;
			
			-- Display actual heal amount
			rDamageOutput.nVal = nWoundHealAmount;
			rDamageOutput.sVal = string.format("%01d", nWoundHealAmount);
		end

	-- Temporary hit points
	elseif rDamageOutput.sType == "temphp" then
		nTempHP = math.max(nTempHP, nTotal);

	-- Damage
	else
		-- Apply any targeted damage effects 
		-- NOTE: Dice determined randomly, instead of rolled
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
			nTotal = nTotal + nDamageEffectTotal;

			if nDamageEffectCount > 0 then
				if nDamageEffectTotal ~= 0 then
					local sFormat = "[" .. Interface.getString("effects_tag") .. " %+d]";
					table.insert(aNotifications, string.format(sFormat, nDamageEffectTotal));
				else
					table.insert(aNotifications, "[" .. Interface.getString("effects_tag") .. "]");
				end
			end
		end
		
		-- Handle avoidance/evasion and half damage
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
			nTotal = math.max(math.floor(nTotal / 2), 1);
		end
		
		-- Apply damage type adjustments
		local nDamageAdjust, bVulnerable, bResist = getDamageAdjust(rSource, rTarget, nTotal, rDamageOutput);
		local nAdjustedDamage = nTotal + nDamageAdjust;
		if nAdjustedDamage < 0 then
			nAdjustedDamage = 0;
		end
		if bResist then
			if nAdjustedDamage <= 0 then
				table.insert(aNotifications, "[RESISTED]");
			else
				table.insert(aNotifications, "[PARTIALLY RESISTED]");
			end
		end
		if bVulnerable then
			table.insert(aNotifications, "[VULNERABLE]");
		end
		
		-- Prepare for concentration checks if damaged
		nConcentrationDamage = nAdjustedDamage;
		
		-- Reduce damage by temporary hit points
		if nTempHP > 0 and nAdjustedDamage > 0 then
			if nAdjustedDamage > nTempHP then
				nAdjustedDamage = nAdjustedDamage - nTempHP;
				nTempHP = 0;
				table.insert(aNotifications, "[PARTIALLY ABSORBED]");
			else
				nTempHP = nTempHP - nAdjustedDamage;
				nAdjustedDamage = 0;
				table.insert(aNotifications, "[ABSORBED]");
			end
		end

		-- Apply remaining damage
		if nAdjustedDamage > 0 then
			-- Remember previous wounds
			local nPrevWounds = nWounds;
			
			-- Apply wounds
			nWounds = math.max(nWounds + nAdjustedDamage, 0);
			
			-- Calculate wounds above HP
			local nRemainder = 0;
			if nWounds > nTotalHP then
				nRemainder = nWounds - nTotalHP;
				nWounds = nTotalHP;
			end
			
			-- Prepare for calcs
			local nodeTargetCT = ActorManager.getCTNode(rTarget);

			-- Deal with remainder damage
			if nRemainder >= nTotalHP then
				table.insert(aNotifications, "[INSTANT DEATH]");
				nDeathSaveFail = 3;
			elseif nRemainder > 0 then
				table.insert(aNotifications, "[DAMAGE EXCEEDS HIT POINTS BY " .. nRemainder.. "]");
				if nPrevWounds >= nTotalHP then
					if rDamageOutput.bCritical then
						nDeathSaveFail = nDeathSaveFail + 2;
					else
						nDeathSaveFail = nDeathSaveFail + 1;
					end
				end
			else
				if OptionsManager.isOption("HRMD", "on") and (nAdjustedDamage >= (nTotalHP / 2)) then
					ActionSave.performSystemShockRoll(nil, rTarget);
				end
			end
			
			-- Handle stable situation
			EffectManager.removeEffect(nodeTargetCT, "Stable");
			
			-- Disable regeneration next round on correct damage type
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
		
		-- Update the damage output variable to reflect adjustments
		rDamageOutput.nVal = nAdjustedDamage;
		rDamageOutput.sVal = string.format("%01d", nAdjustedDamage);
	end
	
	-- Clear death saves if health greater than zero
	if nWounds < nTotalHP then
		nDeathSaveSuccess = 0;
		nDeathSaveFail = 0;
		if EffectManager5E.hasEffect(rTarget, "Stable") then
			EffectManager.removeEffect(ActorManager.getCTNode(rTarget), "Stable");
		end
		if EffectManager5E.hasEffect(rTarget, "Unconscious") then
			EffectManager.removeEffect(ActorManager.getCTNode(rTarget), "Unconscious");
		end
	else
		if not EffectManager5E.hasEffect(rTarget, "Unconscious") then
			EffectManager.addEffect("", "", ActorManager.getCTNode(rTarget), { sName = "Unconscious", nDuration = 0 }, true);
		end
	end

	-- Set health fields
	if nodeTargetCT then
		DB.setValue(nodeTargetCT, "deathsavesuccess", "number", math.min(nDeathSaveSuccess, 3));
		DB.setValue(nodeTargetCT, "deathsavefail", "number", math.min(nDeathSaveFail, 3));
		DB.setValue(nodeTargetCT, "hptemp", "number", nTempHP);
		DB.setValue(nodeTargetCT, "wounds", "number", nWounds);
	elseif ActorManager.isPC(rTarget) then
		local nodeTargetPC = ActorManager.getCreatureNode(rTarget);
		DB.setValue(nodeTargetPC, "hp.deathsavesuccess", "number", math.min(nDeathSaveSuccess, 3));
		DB.setValue(nodeTargetPC, "hp.deathsavefail", "number", math.min(nDeathSaveFail, 3));
		DB.setValue(nodeTargetPC, "hp.temporary", "number", nTempHP);
		DB.setValue(nodeTargetPC, "hp.wounds", "number", nWounds);
	end

	-- Check for status change
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
	
	-- Output results
	messageDamage(rSource, rTarget, bSecret, rDamageOutput.sTypeOutput, sDamage, rDamageOutput.sVal, table.concat(aNotifications, " "));

	-- Remove target after applying damage
	if bRemoveTarget and rSource and rTarget then
		TargetingManager.removeTarget(ActorManager.getCTNodeName(rSource), ActorManager.getCTNodeName(rTarget));
	end

	-- Check for required concentration checks
	if nConcentrationDamage > 0 and ActionSave.hasConcentrationEffects(rTarget) then
		if nWounds < nTotalHP then
			local nTargetDC = math.max(math.floor(nConcentrationDamage / 2), 10);
			ActionSave.performConcentrationRoll(nil, rTarget, nTargetDC);
		else
			ActionSave.expireConcentrationEffects(rTarget);
		end
	end
end