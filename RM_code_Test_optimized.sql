----------------------------------------------------------------------------------------------
-------------------------------------------RM Report------------------------------------------
----------------------------------------------------------------------------------------------

--Τα οικονομικά μεγέθη που θα απεικονίζονται στο εξαγόμενο αρχείο θα αφορούν την τελευταία επικυρωμένη 
--διαβάθμιση σε συγκεκριμένο εύρος ημερομηνιών. Συγκεκριμένα από την ημερά της μετάπτωσης και μετά (> 05-01-2021)  
--έως και την παραμετρική ημερομηνία κλήσης της εφαρμογής την οποία λαμβάνουμε από τον OPCON.
--Θα ληφθεί υπόψη το μοντέλο FA-FIN. Από τους δε ισολογισμούς, θα επιλέγονται εκείνοι με 12μηνη χρήση (period).
--Τα δε στοιχεία Πελάτη (ΑΦΜ,CDI) θα αφορούν την έκδοση(version) του Πελάτη κατά την έγκριση της διαβάθμισης.
--Στην περίπτωση που στα υπολογιζόμενα πεδία, ο παρονομαστής είναι μηδέν, το εξαγόμενο πεδίο θα λαμβάνει την τιμή null.   

-------------------------------------------------------------------------
--find latest approved rating
-------------------------------------------------------------------------

drop table if exists temp1;
create temporary table temp1 as
select distinct on (EntityId) 
        EntityId     
       ,FinancialContext
       ,ApprovedDate 
       ,Updateddate_ 
       ,sourcepopulateddate_ 
from olapts.abratingscenario  --1.146
where cast(approveddate as date) > '2021-01-05' --and cast(ApprovedDate as date) <= @REF_DATE   ----------------!! external parameter
      and cast(ApprovedDate as date) <= '2022-08-05' 
      and isdeleted_ = 'false' and IsLatestApprovedScenario = 'true' and IsPrimary = 'true' 
	  and FinancialContext is not null and FinancialContext <> '###'
      and FinancialContext <> '0:0#0;0#0:#0:0;0:0' and FinancialContext <> '0' and FinancialContext <> '' 
	  and modelid in ('FA_FIN') and length(FinancialContext) >16    
	  and ApprovedDate is not null 
	  --and entityid = '88394'  
order by EntityId,ApprovedDate desc;

--select * from temp1
 
-------------------------------------------------------------------------
--find entityversion, financialid, statementid based on FinancialContext
-------------------------------------------------------------------------

drop table if exists perimeter;
create temporary table perimeter as
select *,
       cast(SUBSTRING((REGEXP_MATCHES(FinancialContext,';([^;#]*)#'))[1], 1) as int) AS entityVersion,
       cast((REGEXP_MATCHES(FinancialContext, '^[^:]*'))[1] as int) AS FinancialId
from (select  *, 
	         (REGEXP_MATCHES(unnest(STRING_TO_ARRAY(REGEXP_REPLACE(FinancialContext, '.*#([^:*]+)', '\1'), ';')), '^(\d+)'))[1] AS statementid
      from temp1
	 )x;

--select * from perimeter

-------------------------------------------------------------------------
-- Financials
-------------------------------------------------------------------------

-----------------------------------
-- Find max versionid_ of balance
-----------------------------------

drop table if exists max_version;
create temporary table max_version as
select  distinct on (per.entityid ,per.financialid,  per.statementid ) per.entityid ,per.financialid,  per.statementid ,(versionid_) max_versionid_
from olapts.abhiststmtbalance balances 
inner join perimeter per
      on balances.statementid = per.statementid 
	  and balances.financialid::int= per.financialid
	  and balances.sourcepopulateddate_ < per.sourcepopulateddate_
where balances.sourcepopulateddate_ < per.sourcepopulateddate_
      --and entityid ='100887' --and per.statementid = '6' --and per.financialid='92813' 
order by per.entityid ,per.financialid,  per.statementid, balances.sourcepopulateddate_ desc ;

--select * from max_version order by entityid

-------------------------
-- Calculate macros 
-------------------------

----OPTIMIZED

drop table if exists macros;
create temporary table macros as
select distinct per.entityid,per.statementid,per.financialid, versionid_, accountid,balances.sourcepopulateddate_,originrounding, originbalance
from olapts.abhiststmtbalance balances 
inner join perimeter per
      on balances.statementid = per.statementid 
	  and balances.financialid::int= per.financialid
	  and balances.sourcepopulateddate_ < per.sourcepopulateddate_
left join max_version max_v
	  on max_v.entityid=per.entityid	  
	  and per.statementid = max_v.statementid 
where accountid in ('1520','1521','1522','1523','1640','1641','1642','1643','1646','1650','2680','2685','2686','2687',
				   '2100','2110','2115','2120','2130','2150','2400','2410','2415','2420','2430','2440','2450','2460','2470',
				   '5950','5960','3400') 
      and balances.sourcepopulateddate_ < per.sourcepopulateddate_
      --and per.entityid ='100066' and per.statementid = '7' 
	  and max_v.max_versionid_=balances.versionid_
	  ;
	  
-----------------------------------FindInventory-----------------------------------

--1520+1521+1522+1523
--Inventories + Finished goods + Work in progress and semi finished products +Raw materials and packing materials 

drop table if exists inventories;
create temporary table inventories as
select entityid, statementid, financialid,sum(inventories) inventories
from (
select distinct entityid,statementid,financialid, versionid_, accountid
       ,coalesce((case when originrounding = '0' then originbalance::decimal(19,2)
					       when originrounding = '1' then originbalance::decimal(19,2)* 1000 
						   when originrounding = '2' then originbalance::decimal(19,2)* 100000 end),0) as inventories
from macros
where accountid in ('1520','1521','1522','1523') 
	)x
group by entityid, statementid, financialid;
	
--select * from inventories where entityid = '100066' and statementid ='5'
--select * from olapts.returninventories('100066', '5')


-----------------------------------FindNettradereceivables-------------------------------

--1640 + 1641 + 1642 + 1643 + 1646 - 1650
--Trade Receivables(Gross)+Checques receivable+Bills receivable+Construction contracts+Due from related companies (trade)-Allow for Doubtful Accounts(-)

drop table if exists Nettradereceivables;
create temporary table Nettradereceivables as
select entityid, statementid, financialid,sum(Nettradereceivables) Nettradereceivables
from (
select  distinct entityid,statementid,financialid,accountid
       ,case when accountid ='1650' 
	         then coalesce((case when originrounding = '0' then -originbalance::decimal(19,2)
					             when originrounding = '1' then -originbalance::decimal(19,2)* 1000
						         when originrounding = '2' then -originbalance::decimal(19,2)* 100000 end),0)
	         else coalesce((case when originrounding = '0' then originbalance::decimal(19,2)
					             when originrounding = '1' then originbalance::decimal(19,2)* 1000
						         when originrounding = '2' then originbalance::decimal(19,2)* 100000 end),0) end as Nettradereceivables
from macros  
where accountid in ('1640','1641','1642','1643','1646','1650')
	)x
group by entityid, statementid, financialid;

--select * from olapts.returnnettradereceivables('100108', '9')
--select * from Nettradereceivables where entityid = '100108' and statementid ='9'

--------------------------------FindTradespayable--------------------------------		

--2680+2685+2686+2687
--Trade Payables(CP) +Cheques and Bills payable + Construction contracts - obligation + (Due to related companies - trade)

drop table if exists Tradespayable;
create temporary table Tradespayable as
select entityid, statementid, financialid,sum(Tradespayable) Tradespayable
from (
select  distinct entityid,statementid,financialid,accountid
       ,coalesce((case when originrounding = '0' then originbalance::decimal(19,2)
					       when originrounding = '1' then originbalance::decimal(19,2)* 1000 
						   when originrounding = '2' then originbalance::decimal(19,2)* 100000 end),0) as Tradespayable					   
from macros  
where accountid in ('2680','2685','2686','2687')
	)x
group by entityid, statementid, financialid;	
	
--select * from olapts.returntradespayable('99993', '4')
--select * from Tradespayable where entityid = '99993' and statementid ='4' 
	
---------------------------------FindTotalBankingDebts---------------------------------								

--2100+2110+2115+2120+2130+2150+2400+2410+2415+2420+2430+2440+2450+2460+2470
--LTD Bank+LTD other + Syndicated Loans + LTD Converitble + LTD Subordinated + Finance Leases (LTP) 
-- +CPLTD Bank + CPLTD Other + CPLTD Syndicated loans + CPLTD Convertible +CPLTD Subordinated + ST Bank Loans Payable 
-- + ST Other Loans Payable + Finance Leases(CP)+ Overdrafts

drop table if exists TotalBankingDebts;
create temporary table TotalBankingDebts as
select entityid, statementid, financialid,sum(TotalBankingDebts) TotalBankingDebts
from (
select  distinct entityid,statementid,financialid,accountid
       ,coalesce((case when originrounding = '0' then originbalance::decimal(19,2)
					       when originrounding = '1' then originbalance::decimal(19,2)* 1000 
						   when originrounding = '2' then originbalance::decimal(19,2)* 100000 end),0) as TotalBankingDebts					   
from macros
where accountid in ('2100','2110','2115','2120','2130','2150','2400','2410','2415','2420','2430','2440','2450','2460','2470')
	)x
group by entityid, statementid, financialid;	
	
--select * from olapts.returntotalbankingdept('100163', '5')
--select * from TotalBankingDebts where entityid = '100163' and statementid ='5' 			
	

----------------------------FindShortTermBankingDebt----------------------------

--2400 + 2410 + 2415 + 2420 + 2430 + 2440 + 2450 + 2460+2470
--CPLTD Bank + CPLTD Other + CPLTD Syndicated loans + CPLTD Convertible +CPLTD Subordinated + ST Bank Loans Payable + ST Other Loans Payable + Finance Leases(CP)+ Overdrafts
	
drop table if exists ShortTermBankingDebt;
create temporary table ShortTermBankingDebt as
select entityid, statementid, financialid,sum(ShortTermBankingDebt) ShortTermBankingDebt
from (
select  distinct entityid,statementid,financialid,accountid
       ,coalesce((case when originrounding = '0' then originbalance::decimal(19,2)
					       when originrounding = '1' then originbalance::decimal(19,2)* 1000 
						   when originrounding = '2' then originbalance::decimal(19,2)* 100000 end),0) as ShortTermBankingDebt					   
from macros
where accountid in ('2400','2410','2415','2420','2430','2440','2450','2460','2470')
	)x
group by entityid, statementid, financialid;	

--select * from olapts.returnshorttermbankingdept('100433', '7')
--select * from ShortTermBankingDebt where entityid = '100433' and statementid ='7' 				
			
---------------------------FindLongTermBankingDebt---------------------------

--2100+2110+2115+2120+2130+2150						
--LTD Bank+LTD other + Syndicated Loans + LTD Converitble+LTD Subordinated + Finance Leases (LTP) 						
								
drop table if exists LongTermBankingDebt;
create temporary table LongTermBankingDebt as
select entityid, statementid, financialid,sum(LongTermBankingDebt) LongTermBankingDebt
from (
select  distinct entityid,statementid,financialid,accountid
       ,coalesce((case when originrounding = '0' then originbalance::decimal(19,2)
					       when originrounding = '1' then originbalance::decimal(19,2)* 1000 
						   when originrounding = '2' then originbalance::decimal(19,2)* 100000 end),0) as LongTermBankingDebt					   
from macros 
where accountid in ('2100','2110','2115','2120','2130','2150')
	)x
group by entityid, statementid, financialid;	

--select * from LongTermBankingDebt where entityid = '100163' and statementid ='8' 
--select * from olapts.returnlongtermbankingdept('100163', '8')
	
-----------------------------Finddividendspayables-----------------------------

--5950 + 5960						
--(Dividends Paid(Fin)+Dvds Paid(Minority S'holders))
																				
drop table if exists dividendspayables;
create temporary table dividendspayables as
select entityid, statementid, financialid,sum(dividendspayables) dividendspayables
from (
select  distinct entityid,statementid,financialid,accountid
       ,coalesce((case when originrounding = '0' then originbalance::decimal(19,2)
					       when originrounding = '1' then originbalance::decimal(19,2)* 1000 
						   when originrounding = '2' then originbalance::decimal(19,2)* 100000 end),0) as dividendspayables					   
from macros 
where accountid in ('5950','5960')
	)x
group by entityid, statementid, financialid;	

--select * from dividendspayables where entityid = '100548' and statementid ='6' 
--select * from olapts.returndividendspayables('100548', '6')


-----------------------------FindInterestExpense (old function returninterestcoverage(!))-----------------------------

--3400
--InterestExpense

drop table if exists InterestExpense;
create temporary table InterestExpense as
select entityid, statementid, financialid,sum(InterestExpense) InterestExpense
from (
select  distinct entityid,statementid,financialid,accountid
       ,coalesce((case when originrounding = '0' then originbalance::decimal(19,2)
					       when originrounding = '1' then originbalance::decimal(19,2)* 1000 
						   when originrounding = '2' then originbalance::decimal(19,2)* 100000 end),0) as InterestExpense					   
from macros	  
where accountid = '3400'
	)x
group by entityid, statementid, financialid;	


--select entityid,* from InterestExpense where entityid = '124716'
--select * from olapts.returninterestcoverage('124688', '1') --816239.74

--poiotikos elegxos 
--select * from olapts.abhiststmtbalance where financialid = '124688' and accountid = '3400'
--select originbalance,* from OLAPTS.facthiststmtbalancelatest where financialid = '124688' and accountid = '3400' and statementid ='1'
--select * from perimeter where entityid = '124716'


-------------------------------commonsharecapital + sharepremium----------------------------------

drop table if exists per;
create temporary table per as 
select distinct on(a.pkid_)   per.entityid, per.financialid,per.statementid,statementyear,statementmonths,commonsharecapital, sharepremium  
from olapts.abuphiststmtfinancials a --3861
join perimeter per 
     on per.entityid::int = a.entityid::int
	 and a.financialid::int = per.financialid
	 and a.statementid = per.statementid 
	 and a.sourcepopulateddate_ <= per.sourcepopulateddate_
order by a.pkid_, a.sourcepopulateddate_ desc;

--
drop table if exists sharecapital_premium;
create temporary table sharecapital_premium as
with cte as (
       select entityid, financialid,statementid, statementyear, statementmonths, commonsharecapital, sharepremium
       from per 
       --where entityid = '118764' 
), cte2 as (select entityid, financialid, statementid, statementyear, statementmonths,commonsharecapital, sharepremium,
                   lag(commonsharecapital,1) over (partition by entityid, financialid order by statementyear) prev_commonsharecapital,
			       lag(sharepremium,1) over (partition by entityid, financialid order by statementyear) prev_sharepremium
            from cte 
           ) 
select entityid, financialid, statementid, statementyear, statementmonths,
       commonsharecapital, prev_commonsharecapital, 
	   commonsharecapital::numeric(19,2) - prev_commonsharecapital::numeric(19,2) as chg_commonsharecapital,
	   sharepremium,prev_sharepremium,
       sharepremium::numeric(19,2) - prev_sharepremium::numeric(19,2)  as chg_sharepremium   
from cte2
order by entityid, financialid, statementyear;

--select * from sharecapital_premium where entityid = '100457' order by entityid

-------------------------------------------------------------------------
-- Final Table
-------------------------------------------------------------------------

drop table if exists final_table;
create temporary table final_table as
select distinct on(a.pkid_) 
	    d.cdicode as cdi
	   ,d.gc18 as afm
	   ,coalesce(a.cashandequivalents::numeric,0.00)::numeric(19,2) as csh
	   ,coalesce(a.ebitda::numeric,0.00)::numeric(19,2) as ebitda
	   ,coalesce(a.totequityreserves::numeric,0.00)::numeric(19,2) as eqty 
	   ,coalesce(a.goodwill::numeric,0.00)::numeric(19,2) as gdwill
	   ,coalesce(a.netprofit::numeric,0.00)::numeric(19,2) as nt_incm
	   ,coalesce(a.salesrevenues::numeric,0.00)::numeric(19,2) as sales_revenue
	   ,coalesce(a.netfixedassets::numeric,0.00)::numeric(19,2) as netfixedassets	   
	   ,coalesce(inventories.inventories::numeric,0.00)::numeric(19,2) as inventory	   
	   ,coalesce(Nettradereceivables.Nettradereceivables::numeric,0.00)::numeric(19,2) as nettradereceivables	   
       ,coalesce(a.totalassets::numeric,0.00)::numeric(19,2) as TotalAssets
	   ,coalesce(a.commonsharecapital::numeric,0.00)::numeric(19,2) as CommonShareCapital
	   ,coalesce(Tradespayable.Tradespayable::numeric,0.00)::numeric(19,2) as tradepayables	      
	   ,coalesce(TotalBankingDebts.TotalBankingDebts::numeric,0.00)::numeric(19,2) as TotalBankingDebt	      	    
	   ,coalesce(ShortTermBankingDebt.ShortTermBankingDebt::numeric,0.00)::numeric(19,2) as ShortTermBankingDebt	      	    	   
	   ,coalesce(LongTermBankingDebt.LongTermBankingDebt::numeric,0.00)::numeric(19,2) as LongTermBankingDebt	      	    	      
	   ,coalesce(a.totalliabilities::numeric,0.00)::numeric(19,2) as TotalLiabilities
	   ,coalesce(a.grossprofit::numeric,0.00)::numeric(19,2) as GrossProfit
       ,coalesce(a.Ebit::numeric,0.00)::numeric(19,2) as Ebit
	   ,a.profitbeforetax::numeric(19,2) as ProfitBeforeTax
	   ,coalesce(a.workingcapital::numeric,0.00)::numeric(19,2) as WorkingCapital
       ,coalesce(a.dcfcffrmoperact::numeric,0.00)::numeric(19,2) as FlowsOperationalActivity
       ,coalesce(a.dcfcffrominvestact::numeric,0.00)::numeric(19,2) as FlowsInvestmentActivity
	   ,coalesce(a.dcfcffromfinact::numeric,0.00)::numeric(19,2) as FlowsFinancingActivity
	   ,sharecapital_premium.chg_commonsharecapital::numeric(19,2)+sharecapital_premium.chg_sharepremium::numeric(19,2) as ChgCommonShareCapital_ChgSharePremium
	   ,coalesce(dividendspayables.dividendspayables::numeric,0.00)::numeric(19,2) as Balancedividendspayable	      	    	         
	   ,coalesce(a.grossprofitmargin::numeric,0.00)::numeric(19,2) as GrossProfitMargin
       ,coalesce(a.netprofitmargin::numeric,0.00)::numeric(19,2) as NetProfitMargin
	   ,coalesce(a.ebitdamargin::numeric,0.00)::numeric(19,2) as EbitdaMargin
       ,case when a.ebitda::decimal(19,2) = 0.00  then 0.00
             else (TotalBankingDebts.TotalBankingDebts::decimal(19,2)/a.ebitda::decimal(19,2))::decimal(19,2)  
        end as TotalBankingDebttoEbitda 	   
	   ,case when a.ebitda::decimal(19,2) = 0.00 then 0.00
	         else ((coalesce(TotalBankingDebts.TotalBankingDebts::decimal(19,2),0.00) - a.cashandequivalents::decimal(19,2))/a.ebitda::decimal(19,2))::decimal(19,2)
		end as NetBankingDebttoEbitda	
       ,coalesce(a.debttoequity::numeric,0.00)::numeric(19,2) as TotalLiabilitiestoTotalEquity
	   ,coalesce(a.returnonassets::numeric,0.00)::numeric(19,2) as ReturnOnAssets
       ,coalesce(a.returnontoteqres::numeric,0.00)::numeric(19,2) as ReturnonEquity
	   ,case when interestexpense.InterestExpense::decimal(19,2)  = 0.00 or interestexpense.InterestExpense is null then '0.00' 
	         else (ebitda::decimal(19,2) / interestexpense.InterestExpense::decimal(19,2))::decimal(19,2) 
		end as interestcoverage
       ,coalesce(a.currentratio::numeric,0.00)::numeric(19,2) as CurrentRatio
	   ,coalesce(a.quickratio::numeric,0.00)::numeric(19,2) as QuickRatio
	   ,a.statementyear::text as fnc_year
	   ,to_char(cast(a.statementdatekey_::varchar(15) as date),'yyyymmdd') as publish_date
	   ,to_char(per.approveddate,'yyyymmdd') as approveddate
	   ,'20210930' as reference_date ----------------!! external parameter
	   ,concat_ws('|',d.entityid::text,d.versionid_::text) as entityid
	   ,per.FinancialId::int as FinancialId -----------------tbd
	   ,per.Statementid::int as Statementid -----------------tbd

from olapts.abuphiststmtfinancials a --3845
join perimeter per 
     on per.entityid::int = a.entityid::int
     and a.entityid = per.entityid
	 and a.financialid::int = per.financialid
	 and a.statementid = per.statementid 
	 and a.sourcepopulateddate_ <= per.sourcepopulateddate_
join olapts.abfactentity d 
     on d.entityid::int = a.entityid::int
	 and d.versionid_ = per.entityversion
left join inventories inventories 
     on per.entityid = inventories.entityid 
	 and per.statementid = inventories.statementid
	 and per.financialid = inventories.financialid
left join Nettradereceivables Nettradereceivables 
     on per.entityid = Nettradereceivables.entityid 
	 and per.statementid = Nettradereceivables.statementid
	 and per.financialid = Nettradereceivables.financialid	
left join Tradespayable Tradespayable 
     on per.entityid = Tradespayable.entityid 
	 and per.statementid = Tradespayable.statementid
	 and per.financialid = Tradespayable.financialid	
left join TotalBankingDebts TotalBankingDebts 
     on per.entityid = TotalBankingDebts.entityid 
	 and per.statementid = TotalBankingDebts.statementid
	 and per.financialid = TotalBankingDebts.financialid	
left join ShortTermBankingDebt ShortTermBankingDebt 
     on per.entityid = ShortTermBankingDebt.entityid 
	 and per.statementid = ShortTermBankingDebt.statementid
	 and per.financialid = ShortTermBankingDebt.financialid	
left join LongTermBankingDebt LongTermBankingDebt 
     on per.entityid = LongTermBankingDebt.entityid 
	 and per.statementid = LongTermBankingDebt.statementid
	 and per.financialid = LongTermBankingDebt.financialid	
left join dividendspayables dividendspayables 
     on per.entityid = dividendspayables.entityid 
	 and per.statementid = dividendspayables.statementid
	 and per.financialid = dividendspayables.financialid		 
left join InterestExpense interestexpense
     on per.entityid = interestexpense.entityid 
	 and per.statementid = interestexpense.statementid
	 and per.financialid = interestexpense.financialid 
left join sharecapital_premium sharecapital_premium
     on per.entityid = sharecapital_premium.entityid 
	 and per.statementid = sharecapital_premium.statementid
	 and per.financialid = sharecapital_premium.financialid      
where 1=1 
      and a.statementmonths = 12     
	  --and a.entityid = '100108'
order by a.pkid_, a.sourcepopulateddate_ desc;


select * from final_table --rows: 3.713, executable time: 11min
order by entityid2, publish_date







---------------------------------------------

select  distinct on(a.pkid_) a.statementmonths,* 
from olapts.abuphiststmtfinancials a
join perimeter per 
     on per.entityid::int = a.entityid::int
     and a.entityid = per.entityid
	 and a.financialid::int = per.financialid
	 and a.statementid = per.statementid 
	 and a.sourcepopulateddate_ <= per.sourcepopulateddate_
join olapts.abfactentity d 
     on d.entityid::int = a.entityid::int
	 and d.versionid_ = per.entityversion	 
	 where a.entityid = '112345' 
order by a.pkid_, a.sourcepopulateddate_ desc



--drop table if exists max_min_year;
--create temporary table max_min_year as
--select entityid, financialid,min(statementyear) min_year,max(statementyear) max_year
--from test
--group by entityid, financialid


drop table if exists max_min_year;
create temporary table max_min_year as
select entityid, financialid,min(fnc_year)::numeric min_year,max(fnc_year)::numeric max_year
from final_table
group by entityid, financialid


select distinct entityid,financialid,generate_series(min_year, max_year) dates from max_min_year  
except
select distinct entityid, financialid, fnc_year::numeric from final_table

"112345"	112345	2018
"106467"	106467	2019


select * from final_table where entityid='112345'
	 