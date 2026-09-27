//+------------------------------------------------------------------+
//|                  XAUUSD_GoldGridRecovery_v2.mq5                  |
//|                                                                  |
//| STRATEGY: RSI-directed first trade + pyramid layers + one-time   |
//| hedge-lock + basket profit lock / trail + intraday loss recovery.|
//| Rebuilt from the shared GoldGridRecovery_EA.mq5 (v1.00) to the   |
//| owner's spec table. Same idea, but every order is gated so the   |
//| basket can never hold more positions than the spec allows.       |
//|                                                                  |
//| SPEC (defaults):                                                 |
//|   Step profit 5 USD : basket P/L (profit + swap of every EA      |
//|       position on this symbol) >= 5 closes all, or starts the    |
//|       trail when trailing is on.                                 |
//|   Pause 15 min      : no new cycle for 15 min after the basket   |
//|       is FULLY closed (verified zero positions).                 |
//|   Base 0.01, mult 1 : layer lot = base lot x multiplier^layer.   |
//|   Recovery cap 0.01 : first trade of a cycle adds lot to win back|
//|       today's closed losses (profit+swap+commission+fee) within  |
//|       150 points; the extra is capped at +0.01 (first lot<=0.02).|
//|   Grid 200 points   : add a layer when price is 200 points past  |
//|       the worst open price on the cycle side.                    |
//|   Layers 1 per side : one layer on top of the first trade.       |
//|   Hedge-lock        : once all layers are used and price moves   |
//|       another 200 points against you, open ONE opposite trade    |
//|       equal to that side's total volume. Hedged once per cycle.  |
//|   Basket trailing   : starts at 5 USD, tracks the peak, closes   |
//|       when profit falls 2 USD from the peak (floor >= 3 USD).    |
//|   Window 01:00-23:00: NEW cycles only, broker SERVER time.       |
//|       Layers and the hedge may still open outside the window.    |
//|   Spread<70 slip 30 : spread checked before every OPENING order; |
//|       slippage is the order's allowed deviation.                 |
//|                                                                  |
//| WHAT v1.00 GOT WRONG (why "it places multiple trades"):          |
//|   1. A partial close-all left orphans, then the cycle restarted  |
//|      on top of them (no "am I flat?" check before a new cycle).  |
//|   2. The trail floor was only checked while P/L >= 5, so once    |
//|      profit dipped below 5 the trail never fired.                |
//|   3. Hedge used base lot + a P/L trigger, not the spec's side    |
//|      volume + 200-point trigger.                                 |
//|   4. Basket-loss loss was counted twice (inflated recovery lot). |
//|   5. Equity-DD re-fired every tick after the 24h pause; restart  |
//|      reset its baseline. Log file was truncated on every init.   |
//|   6. State lived in globals, so a restart lost trail/hedge state.|
//| v2 derives the cycle from LIVE positions every tick, persists    |
//| trail/hedge/pause/day state in terminal global variables, allows |
//| ONE entry attempt per bar, blocks further opens until the last   |
//| fill shows up, and hard-caps the basket at 1 + layers + 1 hedge. |
//|                                                                  |
//| SAFETY: InpEnableLive defaults FALSE (dry run: logs only).       |
//| Strategy Tester always simulates. Requires a HEDGING account.    |
//| No per-position broker stop: protection runs only while the EA   |
//| runs (basket-loss, daily-loss, equity-DD guards).                |
//|                                                                  |
//| CONFIDENCE = STATIC ONLY. No MQL5 compiler on the authoring host |
//| (macOS): NOT compiled, SELFTEST NOT run here. Compile on Windows,|
//| confirm SELFTEST all-green, then test on DEMO before anything.   |
//+------------------------------------------------------------------+
#property copyright "Hari Trading Bot"
#property link      ""
#property version   "2.00"
#property description "Gold Grid Recovery v2 - RSI entry, 1 pyramid layer, one-time hedge-lock, basket lock + trail, capped intraday loss recovery. Position count hard-capped; state rebuilt from live positions. Default DRY RUN."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Cycle & Profit ==="
input double          InpStepProfit        = 5.0;        // Step profit (USD): basket P/L to lock / start trailing
input bool            InpPauseAfterClose   = true;       // Pause new cycles after the basket is fully closed
input int             InpPauseMinutes      = 15;         // Pause duration (minutes)
input ENUM_TIMEFRAMES InpCycleTF           = PERIOD_M15; // Cycle / RSI timeframe

input group "=== Lot Sizing ==="
input double          InpBaseLot           = 0.01;       // Base lot (first trade and layers)
input double          InpPyramidMultiplier = 1.0;        // Layer lot = base x this^layer (1 = no increase)
input double          InpRecoveryLotCap    = 0.01;       // Max EXTRA lot added to a cycle's first trade for recovery

input group "=== Loss Recovery ==="
input bool            InpAutoRecover       = true;       // Add recovery lot for today's closed losses
input int             InpRecoveryPoints    = 150;        // Points in which the extra lot should win the loss back

input group "=== Grid / Pyramid / Hedge ==="
input int             InpGridDistance      = 200;        // Points past the worst open price to add a layer / hedge
input int             InpPyramidLayers     = 1;          // Layers added on top of the first trade
input bool            InpUseHedgeLock      = true;       // After all layers + one more grid step: hedge the side once

input group "=== Basket Management ==="
input double          InpHardBasketTP      = 0.0;        // Hard basket TP (USD), 0 = off (use step lock / trail)
input bool            InpEnableTrailing    = true;       // Trail the basket profit after the step is reached
input double          InpTrailDistance     = 2.0;        // Close when P/L falls this many USD from the peak
input double          InpTrailStep         = 0.0;        // Raise the floor only in steps of this USD (0 = track the peak exactly)

input group "=== Trading Window (broker server time) ==="
input string          InpWindowStart       = "01:00";    // New cycles from (HH:MM). Start == End = all day.
input string          InpWindowEnd         = "23:00";    // New cycles until (HH:MM, exclusive)
input int             InpMaxSpread         = 70;         // Max spread in points for any opening order (0 = off)
input int             InpMaxSlippage       = 30;         // Max slippage (deviation) in points

input group "=== Entry Logic (RSI, closed bar) ==="
input int             InpRSIPeriod         = 14;         // RSI period
input int             InpRSIBuyBelow       = 40;         // BUY cycle when RSI < this
input int             InpRSISellAbove      = 60;         // SELL cycle when RSI > this

input group "=== Safety ==="
input double          InpMaxEquityDD       = 30.0;       // Equity drawdown % from baseline: close all and HALT (latched)
input double          InpMaxDailyLoss      = 5.0;        // Daily equity loss %: no new cycles today (0 = off)
input double          InpMaxBasketLoss     = 50.0;       // Basket floating loss (USD): close all (0 = off)
input bool            InpClearHaltOnInit   = false;      // true = clear a latched equity-DD halt and re-baseline equity on init

input group "=== Execution ==="
input bool            InpEnableLive        = false;      // Send REAL orders (false = DRY RUN). Arm in the client, never here.
input ulong           InpMagic             = 888222;     // Magic number (differs from v1's 888111 so the two never share a basket)
input int             InpRetryCooldownSec  = 10;         // After a rejected order, wait this long before another open
input int             InpConfirmMs         = 10000;      // After a send, block new opens until the position appears (or this many ms)
input bool            InpLogTrades         = true;       // Journal to Common\Files\XAUUSD_GoldGridRecovery_v2_log.csv
input bool            InpVerboseLog        = false;      // Print blocked-order reasons

//+------------------------------------------------------------------+
//| Types / globals                                                  |
//+------------------------------------------------------------------+
struct BasketInfo
  {
   int      buys;
   int      sells;
   double   buyVol;
   double   sellVol;
   double   lowestBuy;     // worst buy open (lowest)
   double   highestSell;   // worst sell open (highest)
   double   pnl;           // profit + swap
   int      dir;           // cycle direction = type of the EARLIEST position (+1 buy, -1 sell, 0 flat)
  };

CTrade   g_trade;
int      g_hRSI = INVALID_HANDLE;
double   g_point = 0.0;
int      g_digits = 0;
double   g_volMin = 0.0, g_volMax = 0.0, g_volStep = 0.0;
int      g_winStart = 0, g_winEnd = 0;

bool     g_selfTestOk = true;
int      g_testsRun = 0, g_testsFailed = 0;

bool     g_halted = false;          // equity-DD latch (persisted)
double   g_baseEquity = 0.0;        // equity-DD baseline (persisted)

bool     g_closing = false;         // close-all in progress: retried every tick until flat
string   g_closeReason = "";
double   g_closePnl = 0.0;
ulong    g_nextCloseTryMs = 0;

int      g_pendingTarget = -1;      // position count we expect after the last fill (-1 = none)
ulong    g_pendingUntilMs = 0;
datetime g_openCooldownUntil = 0;
datetime g_lastEntryBar = 0;        // one entry attempt per cycle-TF bar
ulong    g_lastCommentMs = 0;
bool     g_warnedDryRunPositions = false;
datetime g_lastDailyLossLog = 0;

//+------------------------------------------------------------------+
//| PURE helpers (all fixtured in RunSelfTests)                      |
//+------------------------------------------------------------------+
bool Near(const double a, const double b) { return(MathAbs(a - b) < 1e-8); }

int StepDigits(const double step)
  {
   int d = 0; double probe = step;
   while(d < 8 && MathAbs(probe - MathRound(probe)) > 1e-9) { probe *= 10.0; d++; }
   return(d);
  }

// Round DOWN to the volume step; 0 if below the broker minimum.
double NormalizeLotDown(const double lot, const double minLot, const double maxLot, const double step)
  {
   if(step <= 0.0 || lot <= 0.0) return(0.0);
   double v = MathFloor(lot / step + 1e-9) * step;
   if(v > maxLot && maxLot > 0.0) v = maxLot;
   if(v < minLot - 1e-12) return(0.0);
   return(NormalizeDouble(v, StepDigits(step)));
  }

// +1 BUY when rsi < buyBelow, -1 SELL when rsi > sellAbove, else 0.
int RsiDirection(const double rsi, const int buyBelow, const int sellAbove)
  {
   if(rsi < buyBelow)  return(1);
   if(rsi > sellAbove) return(-1);
   return(0);
  }

// Price has moved `dist` past the worst open price AGAINST the side.
bool LayerTriggered(const bool isBuy, const double price, const double worstOpen, const double dist)
  {
   if(dist <= 0.0 || worstOpen <= 0.0 || price <= 0.0) return(false);
   return(isBuy ? price <= worstOpen - dist + 1e-9 : price >= worstOpen + dist - 1e-9);
  }

double LayerLotRaw(const double baseLot, const double mult, const int layerIndex)
  {
   return(baseLot * MathPow(mult, layerIndex));
  }

// Extra lot so `lossUSD` is won back in the recovery distance. `valuePerLot` =
// USD one lot makes over that distance. Rounded UP to the step (so it actually
// recovers), then capped at `cap` (rounded down to the step).
double RecoveryExtraLot(const double lossUSD, const double valuePerLot, const double cap, const double step)
  {
   if(lossUSD <= 0.0 || valuePerLot <= 0.0 || cap <= 0.0 || step <= 0.0) return(0.0);
   double extra = MathCeil(lossUSD / valuePerLot / step - 1e-9) * step;
   double capOnStep = MathFloor(cap / step + 1e-9) * step;
   if(extra > capOnStep) extra = capOnStep;
   return(NormalizeDouble(extra, StepDigits(step)));
  }

// Trail floor when trailing starts: P/L minus distance, never below 0. Basket P/L is
// profit + swap (the spec's definition); commission is NOT in it, so on a commission
// account a floor near 0 can still realise a small net loss.
double TrailActivateFloor(const double pnl, const double dist)
  {
   return(MathMax(0.0, pnl - dist));
  }

// Raise the floor toward peak - dist. Never lowers it. step > 0 = move only in whole steps.
double TrailRaise(const double curFloor, const double peak, const double dist, const double step)
  {
   double cand = MathMax(0.0, peak - dist);
   if(cand <= curFloor) return(curFloor);
   if(step > 0.0 && cand < curFloor + step - 1e-9) return(curFloor);
   return(cand);
  }

bool TrailShouldClose(const bool active, const double pnl, const double curFloor)
  {
   return(active && pnl <= curFloor);
  }

// "HH:MM" -> minutes since midnight, -1 if malformed.
int ParseHHMM(const string s)
  {
   if(StringLen(s) != 5 || StringGetCharacter(s, 2) != ':') return(-1);
   for(int i = 0; i < 5; i++)
     {
      if(i == 2) continue;
      ushort c = StringGetCharacter(s, i);
      if(c < '0' || c > '9') return(-1);
     }
   int hh = (int)StringToInteger(StringSubstr(s, 0, 2));
   int mm = (int)StringToInteger(StringSubstr(s, 3, 2));
   if(hh > 23 || mm > 59) return(-1);
   return(hh * 60 + mm);
  }

// start == end -> all day. start < end -> [start, end). start > end -> wraps midnight.
bool InWindowMins(const int mins, const int start, const int end)
  {
   if(start == end) return(true);
   if(start < end)  return(mins >= start && mins < end);
   return(mins >= start || mins < end);
  }

bool SpreadOk(const double spreadPts, const int maxSpread)
  {
   if(maxSpread <= 0) return(true);
   return(spreadPts <= (double)maxSpread);
  }

double EquityDDPct(const double baseEquity, const double equity)
  {
   if(baseEquity <= 0.0) return(0.0);
   return((baseEquity - equity) / baseEquity * 100.0);
  }

// First trade + layers + (one hedge if enabled).
int MaxBasketPositionsFor(const int layers, const bool hedge)
  {
   return(1 + MathMax(0, layers) + (hedge ? 1 : 0));
  }

//+------------------------------------------------------------------+
//| Persisted state (terminal global variables, per magic + symbol)  |
//+------------------------------------------------------------------+
// Dry run gets its own namespace so it can never overwrite an armed run's state.
string GvPrefix()
  {
   bool armed = InpEnableLive || (bool)MQLInfoInteger(MQL_TESTER);
   return(StringFormat("GR2_%s%I64u_%s_", armed ? "" : "DRY_", InpMagic, _Symbol));
  }
string GvName(const string k) { return(GvPrefix() + k); }
double GvGet(const string k, const double def)
  {
   string n = GvName(k);
   return(GlobalVariableCheck(n) ? GlobalVariableGet(n) : def);
  }
// flush = write to disk now. MT5 otherwise saves global variables only on a clean
// terminal exit, so a crash would lose a halt / hedge / close-in-progress flag.
void GvSet(const string k, const double v, const bool flush = false)
  {
   GlobalVariableSet(GvName(k), v);
   if(flush) GlobalVariablesFlush();
  }
void GvDel(const string k) { GlobalVariableDel(GvName(k)); }

void ClearCycleState()
  {
   GvDel("cycle"); GvDel("hedged"); GvDel("closing");
   GvDel("trActive"); GvDel("trPeak"); GvDel("trFloor");
   GlobalVariablesFlush();
  }

//+------------------------------------------------------------------+
//| Market / account readers                                         |
//+------------------------------------------------------------------+
bool SendOrdersEnabled() { return(InpEnableLive || (bool)MQLInfoInteger(MQL_TESTER)); }

void ScanBasket(BasketInfo &b)
  {
   b.buys = 0; b.sells = 0; b.buyVol = 0.0; b.sellVol = 0.0;
   b.lowestBuy = 0.0; b.highestSell = 0.0; b.pnl = 0.0; b.dir = 0;
   long earliest = LONG_MAX;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      long   msc   = PositionGetInteger(POSITION_TIME_MSC);
      b.pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(isBuy)
        {
         b.buys++; b.buyVol += vol;
         if(b.lowestBuy == 0.0 || open < b.lowestBuy) b.lowestBuy = open;
        }
      else
        {
         b.sells++; b.sellVol += vol;
         if(b.highestSell == 0.0 || open > b.highestSell) b.highestSell = open;
        }
      if(msc < earliest) { earliest = msc; b.dir = isBuy ? 1 : -1; }
     }
  }

// Net realised P/L today on this symbol for positions THIS EA opened: profit + swap +
// commission + fee. Deals are matched by POSITION, not by the deal's own magic, because
// a manual close or a stop-out writes its closing deal with magic 0. The IN deals are
// looked up over the last 14 days so a basket opened before midnight still counts.
double RealisedTodayUSD()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);
   if(!HistorySelect(dayStart - 14 * 86400, TimeCurrent() + 60)) return(0.0);
   int n = HistoryDealsTotal();
   long ours[];
   int nOurs = 0;
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      ArrayResize(ours, nOurs + 1);
      ours[nOurs++] = HistoryDealGetInteger(d, DEAL_POSITION_ID);
     }
   double sum = 0.0;
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if((datetime)HistoryDealGetInteger(d, DEAL_TIME) < dayStart) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      long pos = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      bool mine = false;
      for(int k = 0; k < nOurs && !mine; k++) mine = (ours[k] == pos);
      if(!mine) continue;
      sum += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
             HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
     }
   return(sum);
  }

// USD one lot makes over `points` in the trade direction (broker's own calc).
double ValueOfPointsPerLot(const bool isBuy, const int points)
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) return(0.0);
   double price  = isBuy ? t.ask : t.bid;
   double target = isBuy ? price + points * g_point : price - points * g_point;
   double v = 0.0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, price, target, v)) return(0.0);
   return(MathAbs(v));
  }

double CurrentSpreadPts()
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t) || g_point <= 0.0) return(1e9);
   return((t.ask - t.bid) / g_point);
  }

//+------------------------------------------------------------------+
//| Day / pause / window guards                                      |
//+------------------------------------------------------------------+
void UpdateDay()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   double key = dt.year * 10000.0 + dt.mon * 100.0 + dt.day;
   if(GvGet("dayKey", 0.0) != key)
     {
      GvSet("dayKey", key);
      GvSet("dayEq", AccountInfoDouble(ACCOUNT_EQUITY));
      // Touch the long-lived keys daily: MT5 deletes a global variable untouched for 4 weeks.
      GvSet("baseEq", g_baseEquity > 0.0 ? g_baseEquity : AccountInfoDouble(ACCOUNT_EQUITY));
      if(g_halted) GvSet("halted", 1.0);
      GlobalVariablesFlush();
      PrintFormat("New server day %.0f: day-start equity %.2f", key, AccountInfoDouble(ACCOUNT_EQUITY));
     }
  }

bool DailyLossHit()
  {
   if(InpMaxDailyLoss <= 0.0) return(false);
   double dayEq = GvGet("dayEq", 0.0);
   if(dayEq <= 0.0) return(false);
   return((dayEq - AccountInfoDouble(ACCOUNT_EQUITY)) / dayEq * 100.0 >= InpMaxDailyLoss);
  }

bool PauseActive() { return(TimeCurrent() < (datetime)GvGet("pauseEnd", 0.0)); }

void StartPause()
  {
   if(!InpPauseAfterClose || InpPauseMinutes <= 0) return;
   datetime until = TimeCurrent() + InpPauseMinutes * 60;
   GvSet("pauseEnd", (double)until, true);
   PrintFormat("PAUSED %d min (until %s server time)", InpPauseMinutes, TimeToString(until, TIME_DATE | TIME_MINUTES));
  }

bool InTradingWindow()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return(InWindowMins(dt.hour * 60 + dt.min, g_winStart, g_winEnd));
  }

//+------------------------------------------------------------------+
//| Journal                                                          |
//+------------------------------------------------------------------+
void Journal(const string action, const string side, const double lots, const double price,
             const double basketPnl, const string info)
  {
   if(!InpLogTrades) return;
   int h = FileOpen("XAUUSD_GoldGridRecovery_v2_log.csv",
                    FILE_COMMON | FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   if(FileSize(h) == 0)
      FileWrite(h, "time", "symbol", "mode", "action", "side", "lots", "price", "basket_pnl", "realised_today", "info");
   FileSeek(h, 0, SEEK_END);
   string mode = (bool)MQLInfoInteger(MQL_TESTER) ? "TESTER" : (InpEnableLive ? "LIVE" : "DRY_RUN");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), _Symbol, mode, action, side,
             DoubleToString(lots, 2), DoubleToString(price, g_digits), DoubleToString(basketPnl, 2),
             DoubleToString(RealisedTodayUSD(), 2), info);
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Order gate: the ONLY place a position is opened                  |
//+------------------------------------------------------------------+
// A fill is "pending" until the scan shows the new position (or the confirm
// window expires). While pending, nothing else may open - this is what stops
// the same signal from being sent twice.
bool IsPending(const BasketInfo &b)
  {
   if(g_pendingTarget < 0) return(false);
   if(b.buys + b.sells >= g_pendingTarget || GetTickCount64() > g_pendingUntilMs)
     { g_pendingTarget = -1; return(false); }
   return(true);
  }

bool CanOpenNow(const BasketInfo &b, string &why)
  {
   why = "";
   if(!g_selfTestOk)                         { why = "SELFTEST_FAILED";  return(false); }
   if(g_halted)                              { why = "EQUITY_DD_HALT";   return(false); }
   if(g_closing)                             { why = "CLOSING";          return(false); }
   if(IsPending(b))                          { why = "AWAITING_FILL";    return(false); }
   if(TimeCurrent() < g_openCooldownUntil)   { why = "RETRY_COOLDOWN";   return(false); }
   if(InpEnableLive && !(bool)MQLInfoInteger(MQL_TESTER) &&
      (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)))
                                             { why = "TRADE_NOT_ALLOWED"; return(false); }
   if(b.buys + b.sells >= MaxBasketPositionsFor(InpPyramidLayers, InpUseHedgeLock))
                                             { why = "BASKET_FULL";      return(false); }
   if(!SpreadOk(CurrentSpreadPts(), InpMaxSpread)) { why = "SPREAD_TOO_WIDE"; return(false); }
   return(true);
  }

bool OpenMarket(const bool isBuy, const double lot, const string tag, const BasketInfo &b)
  {
   string side = isBuy ? "BUY" : "SELL";
   if(lot <= 0.0) { PrintFormat("%s %s skipped: lot is zero after normalisation", tag, side); return(false); }
   string comment = "GR2_" + tag;
   if(!SendOrdersEnabled())
     {
      PrintFormat("DRY_RUN would %s %.2f %s (%s)", side, lot, _Symbol, tag);
      Journal("DRY_RUN_" + tag, side, lot, 0.0, b.pnl, "");
      g_openCooldownUntil = TimeCurrent() + InpRetryCooldownSec;
      return(false);
     }
   bool sent = isBuy ? g_trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, comment)
                     : g_trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, comment);
   uint rc = g_trade.ResultRetcode();
   bool ok = sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
   if(!ok)
     {
      PrintFormat("ORDER REJECTED %s %s %.2f rc=%u %s", tag, side, lot, rc, g_trade.ResultRetcodeDescription());
      Journal("REJECTED_" + tag, side, lot, 0.0, b.pnl, IntegerToString(rc));
      g_openCooldownUntil = TimeCurrent() + InpRetryCooldownSec;
      // A timeout / lost connection can still fill on the server. Treat every failed
      // send as possibly filled: wait for it to appear (or the window to lapse) before
      // any other open, so a "rejected" order that actually filled is never re-sent.
      g_pendingTarget  = b.buys + b.sells + 1;
      g_pendingUntilMs = GetTickCount64() + (ulong)MathMax(InpConfirmMs, InpRetryCooldownSec * 1000);
      return(false);
     }
   g_pendingTarget  = b.buys + b.sells + 1;
   g_pendingUntilMs = GetTickCount64() + (ulong)MathMax(0, InpConfirmMs);
   double px = g_trade.ResultPrice();
   PrintFormat("OPENED %s %s %.2f @ %.*f", tag, side, lot, g_digits, px);
   Journal("OPEN_" + tag, side, lot, px, b.pnl, "");
   return(true);
  }

//+------------------------------------------------------------------+
//| Close-all: retried every tick until the basket is verified flat  |
//+------------------------------------------------------------------+
void CloseAllOnce()
  {
   if(GetTickCount64() < g_nextCloseTryMs) return;
   g_nextCloseTryMs = GetTickCount64() + 500;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(!g_trade.PositionClose(t, InpMaxSlippage) ||
         (g_trade.ResultRetcode() != TRADE_RETCODE_DONE && g_trade.ResultRetcode() != TRADE_RETCODE_DONE_PARTIAL))
         PrintFormat("close %I64u failed rc=%u %s - retrying", t, g_trade.ResultRetcode(),
                     g_trade.ResultRetcodeDescription());
     }
  }

void BeginClose(const string reason, const double pnl)
  {
   if(!g_closing)
     {
      g_closing = true; g_closeReason = reason; g_closePnl = pnl;
      GvSet("closing", 1.0, true);      // survives a restart: leftovers get closed, never re-gridded
      PrintFormat("CLOSE ALL: %s | basket P/L %.2f", reason, pnl);
      Journal("CLOSE_BEGIN", "", 0.0, 0.0, pnl, reason);
     }
   g_nextCloseTryMs = 0;
   CloseAllOnce();
  }

// Runs once the scan confirms zero positions: log, reset the cycle, start the pause.
void FinishClose()
  {
   PrintFormat("CYCLE CLOSED: %s | basket P/L at trigger %.2f | realised today %.2f",
               g_closeReason, g_closePnl, RealisedTodayUSD());
   Journal("CYCLE_CLOSED", "", 0.0, 0.0, g_closePnl, g_closeReason);
   ClearCycleState();
   StartPause();
   g_closing = false; g_closeReason = ""; g_closePnl = 0.0;
   g_pendingTarget = -1;
  }

//+------------------------------------------------------------------+
//| Safety                                                           |
//+------------------------------------------------------------------+
// true = stop processing this tick.
bool CheckEquityGuard(const BasketInfo &b)
  {
   int total = b.buys + b.sells;
   if(!g_halted && InpMaxEquityDD > 0.0)
     {
      double dd = EquityDDPct(g_baseEquity, AccountInfoDouble(ACCOUNT_EQUITY));
      if(dd >= InpMaxEquityDD)
        {
         g_halted = true; GvSet("halted", 1.0, true);
         PrintFormat("EMERGENCY: equity DD %.1f%% >= %.1f%% from baseline %.2f - closing all and HALTING. "
                     "Set InpClearHaltOnInit=true and re-attach to resume.", dd, InpMaxEquityDD, g_baseEquity);
        }
     }
   if(!g_halted) return(false);
   if(total > 0) BeginClose("EQUITY_DD_HALT", b.pnl);
   return(true);
  }

//+------------------------------------------------------------------+
//| Basket: loss limit, hard TP, step lock, trailing                 |
//+------------------------------------------------------------------+
void ManageBasket(const BasketInfo &b)
  {
   double pnl = b.pnl;
   if(InpMaxBasketLoss > 0.0 && pnl <= -InpMaxBasketLoss) { BeginClose("BASKET_LOSS_LIMIT", pnl); return; }
   if(InpHardBasketTP > 0.0 && pnl >= InpHardBasketTP)    { BeginClose("HARD_BASKET_TP", pnl);    return; }

   if(!InpEnableTrailing)
     {
      if(pnl >= InpStepProfit) BeginClose("STEP_PROFIT", pnl);
      return;
     }

   bool   active = GvGet("trActive", 0.0) > 0.5;
   double peak   = GvGet("trPeak", 0.0);
   double trFloor  = GvGet("trFloor", 0.0);
   if(!active)
     {
      if(pnl < InpStepProfit) return;
      peak = pnl; trFloor = TrailActivateFloor(pnl, InpTrailDistance);
      GvSet("trActive", 1.0); GvSet("trPeak", peak); GvSet("trFloor", trFloor);
      PrintFormat("TRAIL ON: P/L %.2f floor %.2f", pnl, trFloor);
      return;
     }
   if(pnl > peak)
     {
      peak = pnl;
      double nf = TrailRaise(trFloor, peak, InpTrailDistance, InpTrailStep);
      GvSet("trPeak", peak);
      if(nf > trFloor) { trFloor = nf; GvSet("trFloor", trFloor); if(InpVerboseLog) PrintFormat("TRAIL peak %.2f floor %.2f", peak, trFloor); }
     }
   // Checked on EVERY tick once active - v1 only checked while P/L >= step, so the trail never fired.
   if(TrailShouldClose(true, pnl, trFloor)) BeginClose("TRAIL_STOP", pnl);
  }

//+------------------------------------------------------------------+
//| Grid: layers on the cycle side, then one hedge                   |
//+------------------------------------------------------------------+
void ManageGrid(const BasketInfo &b)
  {
   if(b.dir == 0) return;
   bool   isBuy   = (b.dir > 0);
   int    same    = isBuy ? b.buys  : b.sells;
   int    opp     = isBuy ? b.sells : b.buys;
   double worst   = isBuy ? b.lowestBuy : b.highestSell;
   double sideVol = isBuy ? b.buyVol : b.sellVol;

   // Once hedged the basket is locked: no more layers, no second hedge.
   if(opp > 0 || GvGet("hedged", 0.0) > 0.5) return;

   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) return;
   double price = isBuy ? t.ask : t.bid;
   double dist  = InpGridDistance * g_point;
   if(!LayerTriggered(isBuy, price, worst, dist)) return;

   string why;
   if(!CanOpenNow(b, why)) { if(InpVerboseLog) PrintFormat("grid open blocked: %s", why); return; }

   int maxSame = 1 + MathMax(0, InpPyramidLayers);
   if(same < maxSame)
     {
      double lot = NormalizeLotDown(LayerLotRaw(InpBaseLot, InpPyramidMultiplier, same), g_volMin, g_volMax, g_volStep);
      OpenMarket(isBuy, lot, StringFormat("L%d", same), b);
      return;
     }
   if(!InpUseHedgeLock) return;
   double hedgeLot = NormalizeLotDown(sideVol, g_volMin, g_volMax, g_volStep);
   // A second hedge is impossible: the pending-fill gate blocks until it shows up,
   // then opp > 0 / the persisted "hedged" flag lock the basket.
   if(OpenMarket(!isBuy, hedgeLot, "HEDGE", b))
     {
      GvSet("hedged", 1.0, true);
      PrintFormat("HEDGE-LOCK: %s %.2f against %d %s position(s), basket P/L %.2f",
                  isBuy ? "SELL" : "BUY", hedgeLot, same, isBuy ? "BUY" : "SELL", b.pnl);
     }
  }

//+------------------------------------------------------------------+
//| Entry: RSI on the last CLOSED bar, one attempt per bar           |
//+------------------------------------------------------------------+
void TryStartCycle(const BasketInfo &b)
  {
   datetime bar = iTime(_Symbol, InpCycleTF, 0);
   if(bar == 0 || bar == g_lastEntryBar) return;
   if(PauseActive() || !InTradingWindow()) return;
   if(DailyLossHit())
     {
      if(bar != g_lastDailyLossLog) { Print("Daily loss limit hit - no new cycles today"); g_lastDailyLossLog = bar; }
      return;
     }
   string why;
   if(!CanOpenNow(b, why)) { if(InpVerboseLog) PrintFormat("entry blocked: %s", why); return; }   // bar NOT consumed: retry next tick

   double rsi[];
   if(CopyBuffer(g_hRSI, 0, 1, 1, rsi) < 1) return;
   int dir = RsiDirection(rsi[0], InpRSIBuyBelow, InpRSISellAbove);
   g_lastEntryBar = bar;                        // from here the bar is consumed: at most ONE send per bar
   if(dir == 0) return;
   bool isBuy = (dir > 0);

   double extra = 0.0, loss = 0.0;
   if(InpAutoRecover)
     {
      double realised = RealisedTodayUSD();
      loss = (realised < 0.0) ? -realised : 0.0;
      if(loss > 0.0)
         extra = RecoveryExtraLot(loss, ValueOfPointsPerLot(isBuy, InpRecoveryPoints), InpRecoveryLotCap, g_volStep);
     }
   double lot = NormalizeLotDown(InpBaseLot + extra, g_volMin, g_volMax, g_volStep);

   if(OpenMarket(isBuy, lot, "L0", b))
     {
      ClearCycleState();
      GvSet("cycle", 1.0, true);
      PrintFormat("CYCLE START %s %.2f (base %.2f + recovery %.2f for %.2f USD loss) RSI %.1f",
                  isBuy ? "BUY" : "SELL", lot, InpBaseLot, extra, loss, rsi[0]);
     }
  }

//+------------------------------------------------------------------+
//| Chart display                                                    |
//+------------------------------------------------------------------+
void UpdateChartComment(const BasketInfo &b)
  {
   if((bool)MQLInfoInteger(MQL_TESTER) && !(bool)MQLInfoInteger(MQL_VISUAL_MODE)) return;
   if(GetTickCount64() < g_lastCommentMs + 1000) return;
   g_lastCommentMs = GetTickCount64();
   string state = g_halted ? "HALTED (equity DD)" : g_closing ? "CLOSING" :
                  (b.buys + b.sells > 0) ? "ACTIVE" : PauseActive() ? "PAUSED" : "IDLE";
   bool trail = GvGet("trActive", 0.0) > 0.5;
   Comment(StringFormat(
      "=== Gold Grid Recovery v2 (%s) ===\n"
      "State: %s | Dir: %s | Positions %d (BUY %d / SELL %d) | Hedged: %s\n"
      "Basket P/L: %.2f | Step: %.2f | Trail: %s\n"
      "Realised today: %.2f | Spread: %.0f pts | SELFTEST: %s",
      SendOrdersEnabled() ? ((bool)MQLInfoInteger(MQL_TESTER) ? "TESTER" : "LIVE") : "DRY RUN",
      state, b.dir > 0 ? "BUY" : b.dir < 0 ? "SELL" : "-", b.buys + b.sells, b.buys, b.sells,
      (b.buys > 0 && b.sells > 0) || GvGet("hedged", 0.0) > 0.5 ? "YES" : "NO",
      b.pnl, InpStepProfit,
      trail ? StringFormat("ON peak %.2f floor %.2f", GvGet("trPeak", 0.0), GvGet("trFloor", 0.0)) : "OFF",
      RealisedTodayUSD(), CurrentSpreadPts(), g_selfTestOk ? "green" : "FAILED - not trading"));
  }

//+------------------------------------------------------------------+
//| Self tests                                                       |
//+------------------------------------------------------------------+
void Check(const bool ok, const string name)
  {
   g_testsRun++;
   if(!ok) { g_testsFailed++; PrintFormat("SELFTEST FAIL  %s", name); }
   else if(InpVerboseLog) PrintFormat("SELFTEST pass  %s", name);
  }

void RunSelfTests()
  {
   g_testsRun = 0; g_testsFailed = 0;

   // RSI direction (thresholds are strict).
   Check(RsiDirection(35.0, 40, 60) == 1,  "RSI 35 < 40 -> BUY");
   Check(RsiDirection(65.0, 40, 60) == -1, "RSI 65 > 60 -> SELL");
   Check(RsiDirection(50.0, 40, 60) == 0,  "RSI 50 -> no signal");
   Check(RsiDirection(40.0, 40, 60) == 0,  "RSI exactly 40 -> no signal");

   // Grid trigger: gold point 0.01, 200 points = 2.00.
   Check(LayerTriggered(true, 1998.00, 2000.00, 2.0),   "buy: 200 pts below worst -> layer");
   Check(!LayerTriggered(true, 1998.50, 2000.00, 2.0),  "buy: only 150 pts below -> no layer");
   Check(LayerTriggered(false, 2002.00, 2000.00, 2.0),  "sell: 200 pts above worst -> layer");
   Check(!LayerTriggered(false, 2001.00, 2000.00, 2.0), "sell: only 100 pts above -> no layer");
   Check(!LayerTriggered(true, 1990.00, 0.0, 2.0),      "no worst price -> no layer");

   // Lots.
   Check(Near(NormalizeLotDown(0.019, 0.01, 100.0, 0.01), 0.01), "0.019 rounds DOWN to 0.01");
   Check(Near(NormalizeLotDown(0.02, 0.01, 100.0, 0.01), 0.02),  "0.02 stays 0.02 (no float drift)");
   Check(Near(NormalizeLotDown(0.005, 0.01, 100.0, 0.01), 0.0),  "below min lot -> 0");
   Check(Near(NormalizeLotDown(150.0, 0.01, 100.0, 0.01), 100.0), "capped at max lot");
   Check(Near(LayerLotRaw(0.01, 1.0, 1), 0.01), "mult 1: layer 1 = 0.01");
   Check(Near(LayerLotRaw(0.01, 2.0, 2), 0.04), "mult 2: layer 2 = 0.04");

   // Recovery: 150 pts on 1 lot of gold ~ 150 USD.
   Check(Near(RecoveryExtraLot(3.0, 150.0, 0.01, 0.01), 0.01),  "3 USD loss wants 0.02 -> capped +0.01");
   Check(Near(RecoveryExtraLot(0.5, 150.0, 0.01, 0.01), 0.01),  "small loss rounds UP to one step");
   Check(Near(RecoveryExtraLot(0.0, 150.0, 0.01, 0.01), 0.0),   "no loss -> no extra");
   Check(Near(RecoveryExtraLot(3.0, 150.0, 0.0, 0.01), 0.0),    "cap 0 -> recovery off");
   Check(Near(NormalizeLotDown(0.01 + RecoveryExtraLot(100.0, 150.0, 0.01, 0.01), 0.01, 100.0, 0.01), 0.02),
         "first lot is at most 0.02 with defaults");

   // Trailing: start 5, distance 2.
   Check(Near(TrailActivateFloor(5.0, 2.0), 3.0), "trail starts at 5 -> floor 3");
   Check(Near(TrailActivateFloor(1.0, 2.0), 0.0), "floor never below 0");
   Check(Near(TrailRaise(3.0, 6.5, 2.0, 0.0), 4.5), "peak 6.5 -> floor 4.5 (exact tracking)");
   Check(Near(TrailRaise(4.5, 4.0, 2.0, 0.0), 4.5), "floor never lowers");
   Check(Near(TrailRaise(3.0, 5.5, 2.0, 1.0), 3.0), "step 1: 3.5 < 3+1 -> floor stays");
   Check(Near(TrailRaise(3.0, 6.0, 2.0, 1.0), 4.0), "step 1: 4.0 >= 3+1 -> floor 4");
   Check(TrailShouldClose(true, 4.4, 4.5),   "P/L 4.4 <= floor 4.5 -> close (even though < step)");
   Check(!TrailShouldClose(true, 4.6, 4.5),  "P/L above floor -> hold");
   Check(!TrailShouldClose(false, -3.0, 4.5), "trail inactive -> never closes");

   // Window (server minutes).
   Check(ParseHHMM("01:00") == 60 && ParseHHMM("23:00") == 1380, "parse 01:00 / 23:00");
   Check(ParseHHMM("25:00") == -1 && ParseHHMM("1:00") == -1 && ParseHHMM("ab:cd") == -1, "reject bad times");
   Check(InWindowMins(60, 60, 1380),    "01:00 inside [01:00, 23:00)");
   Check(!InWindowMins(1380, 60, 1380), "23:00 is outside (end exclusive)");
   Check(!InWindowMins(30, 60, 1380),   "00:30 outside");
   Check(InWindowMins(30, 1380, 60),    "wrap window 23:00-01:00 includes 00:30");
   Check(!InWindowMins(600, 1380, 60),  "wrap window excludes 10:00");
   Check(InWindowMins(600, 0, 0),       "start == end -> all day");

   // Spread / equity / caps.
   Check(SpreadOk(69.0, 70) && !SpreadOk(71.0, 70) && SpreadOk(1000.0, 0), "spread gate");
   Check(Near(EquityDDPct(1000.0, 700.0), 30.0) && Near(EquityDDPct(0.0, 500.0), 0.0), "equity DD pct");
   Check(MaxBasketPositionsFor(1, true) == 3,  "1 layer + hedge -> max 3 positions");
   Check(MaxBasketPositionsFor(1, false) == 2, "1 layer, no hedge -> max 2");
   Check(MaxBasketPositionsFor(0, true) == 2,  "0 layers + hedge -> max 2");

   g_selfTestOk = (g_testsFailed == 0);
   PrintFormat("SELFTEST SUMMARY: %d checks, %d failed%s", g_testsRun, g_testsFailed,
               g_selfTestOk ? " - all green" : " - EA WILL NOT OPEN TRADES");
  }

//+------------------------------------------------------------------+
//| Lifecycle                                                        |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(g_point <= 0.0 || g_volStep <= 0.0) { Print("OnInit failed: symbol point/volume step is zero"); return(INIT_FAILED); }

   // Input validation - refuse to run on a config the spec cannot mean.
   g_winStart = ParseHHMM(InpWindowStart);
   g_winEnd   = ParseHHMM(InpWindowEnd);
   if(g_winStart < 0 || g_winEnd < 0) { PrintFormat("OnInit failed: window must be HH:MM (got '%s' / '%s')", InpWindowStart, InpWindowEnd); return(INIT_FAILED); }
   if(InpBaseLot <= 0.0 || InpGridDistance <= 0 || InpPyramidLayers < 0 || InpStepProfit <= 0.0 ||
      InpPyramidMultiplier <= 0.0 || InpRSIPeriod <= 0 || InpRSIBuyBelow >= InpRSISellAbove)
     { Print("OnInit failed: invalid inputs (base lot, grid, layers, step, multiplier, RSI period, or RSI buy >= sell)"); return(INIT_FAILED); }
   if(NormalizeLotDown(InpBaseLot, g_volMin, g_volMax, g_volStep) <= 0.0)
     { PrintFormat("OnInit failed: base lot %.2f is below the broker minimum %.2f", InpBaseLot, g_volMin); return(INIT_FAILED); }
   if((InpEnableTrailing && InpTrailDistance <= 0.0) || InpTrailStep < 0.0 || InpMaxSlippage < 0 ||
      InpMaxSpread < 0 || InpPauseMinutes < 0 || InpRetryCooldownSec < 0 || InpConfirmMs < 0 ||
      InpRecoveryLotCap < 0.0 || (InpAutoRecover && InpRecoveryPoints <= 0) ||
      InpMaxEquityDD < 0.0 || InpMaxDailyLoss < 0.0 || InpMaxBasketLoss < 0.0 || InpHardBasketTP < 0.0)
     { Print("OnInit failed: a distance, step, slippage, spread, time, cap or safety input is negative/zero where it cannot be."); return(INIT_FAILED); }
   if(InpEnableTrailing && InpTrailDistance >= InpStepProfit)
      PrintFormat("WARNING: trail distance %.2f >= step %.2f - the floor starts at 0 (break-even lock).", InpTrailDistance, InpStepProfit);

   // A grid with layers + hedge needs a HEDGING account: on netting every order merges into one position.
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     { Print("OnInit failed: this EA needs a HEDGING account (layers and hedge-lock are separate positions)."); return(INIT_FAILED); }

   if((bool)MQLInfoInteger(MQL_TESTER)) GlobalVariablesDeleteAll(GvPrefix());   // each tester run starts clean

   g_hRSI = iRSI(_Symbol, InpCycleTF, InpRSIPeriod, PRICE_CLOSE);
   if(g_hRSI == INVALID_HANDLE) { Print("OnInit failed: RSI handle"); return(INIT_FAILED); }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpMaxSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   if(InpClearHaltOnInit)
     {
      // Only acts on an existing halt, so leaving it true never re-baselines a healthy run.
      if(GvGet("halted", 0.0) > 0.5)
        {
         GvDel("halted"); GvDel("baseEq");
         Print("Equity-DD halt CLEARED; baseline reset to current equity.");
        }
      Print("WARNING: InpClearHaltOnInit is TRUE - set it back to false, or a future halt is cleared on the next restart.");
     }
   if(!GlobalVariableCheck(GvName("baseEq"))) GvSet("baseEq", AccountInfoDouble(ACCOUNT_EQUITY), true);
   g_baseEquity = GvGet("baseEq", AccountInfoDouble(ACCOUNT_EQUITY));
   g_halted     = GvGet("halted", 0.0) > 0.5;
   // A close-all interrupted by a restart resumes: leftovers are closed, never re-gridded.
   if(GvGet("closing", 0.0) > 0.5)
     {
      g_closing = true; g_closeReason = "RESUMED_AFTER_RESTART"; g_closePnl = 0.0;
      Print("Resuming an interrupted close-all.");
     }
   UpdateDay();

   RunSelfTests();

   BasketInfo b; ScanBasket(b);
   PrintFormat("=== Grid Recovery v2 | %s %s | mode=%s | magic=%I64u | base %.2f x%.2f | grid %d pts | layers %d | hedge %s ===",
               _Symbol, EnumToString(InpCycleTF),
               (bool)MQLInfoInteger(MQL_TESTER) ? "STRATEGY TESTER" : (InpEnableLive ? "*** LIVE ORDERS ***" : "DRY RUN (no orders)"),
               InpMagic, InpBaseLot, InpPyramidMultiplier, InpGridDistance, InpPyramidLayers, InpUseHedgeLock ? "on" : "off");
   PrintFormat("step %.2f | trail %s dist %.2f step %.2f | pause %d min | window %s-%s server | spread<=%d slip %d | recovery %s cap +%.2f in %d pts",
               InpStepProfit, InpEnableTrailing ? "on" : "off", InpTrailDistance, InpTrailStep, InpPauseMinutes,
               InpWindowStart, InpWindowEnd, InpMaxSpread, InpMaxSlippage, InpAutoRecover ? "on" : "off",
               InpRecoveryLotCap, InpRecoveryPoints);
   PrintFormat("safety: basket loss %.2f USD | daily loss %.1f%% | equity DD %.1f%% of %.2f%s | max positions %d | existing positions %d",
               InpMaxBasketLoss, InpMaxDailyLoss, InpMaxEquityDD, g_baseEquity, g_halted ? " [HALTED]" : "",
               MaxBasketPositionsFor(InpPyramidLayers, InpUseHedgeLock), b.buys + b.sells);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   Comment("");
  }

void OnTick()
  {
   UpdateDay();
   BasketInfo b; ScanBasket(b);
   int total = b.buys + b.sells;
   UpdateChartComment(b);

   // Dry run never touches positions it finds (they may belong to an armed run).
   if(!SendOrdersEnabled() && total > 0)
     {
      if(!g_warnedDryRunPositions) { PrintFormat("DRY RUN: %d position(s) with magic %I64u exist - NOT managing them.", total, InpMagic); g_warnedDryRunPositions = true; }
      return;
     }

   if(g_closing)
     {
      if(total == 0) FinishClose(); else CloseAllOnce();
      return;
     }
   if(CheckEquityGuard(b)) return;

   if(total > 0)
     {
      ManageBasket(b);
      if(!g_closing) ManageGrid(b);
      return;
     }

   // Flat. A just-sent order may not be visible yet - never treat that as a closed cycle.
   if(IsPending(b)) return;
   if(GvGet("cycle", 0.0) > 0.5)
     {
      g_closeReason = "CLOSED_OUTSIDE_EA"; g_closePnl = 0.0;   // manual close / stop-out
      FinishClose();
      return;
     }
   TryStartCycle(b);
  }
//+------------------------------------------------------------------+
