//+------------------------------------------------------------------+
//|                                   aman_sc_agentspaces_v2.mq5     |
//|                                                                  |
//| TRADES THE TSI_Trend LINE CROSSOVERS (GOLD M5 by default).       |
//|                                                                  |
//| The TSI_Trend indicator draws ONE line: green while the TSI line |
//| is above its signal (bullish), red while below (bearish). Its    |
//| colour flips on exactly the crossover bar. This EA reads that    |
//| SAME colour buffer, so every trade sits on a visible flip.       |
//|                                                                  |
//| ENTRY (evaluated once per closed bar):                           |
//|   1. The line flipped green (BUY) / red (SELL) within the last   |
//|      InpCrossLookback closed bars and is still that colour.      |
//|   2. FILLED candle: the last closed candle has a solid body in   |
//|      the trade direction (body >= InpMinBodyFrac of its range).  |
//|   3. EMA rule (from the v8 chart): the candle closes above all   |
//|      three EMAs 9/21/48 for a BUY, below all three for a SELL    |
//|      (EMA_FULL_STACK also requires 9>21>48 / 9<21<48).           |
//|   4. ADX >= InpMinADX (skip flat chop), spread, session, daily   |
//|      loss and position-limit guards.                             |
//|   Each crossover is traded at most once.                         |
//|                                                                  |
//| EXIT: SL = InpSlAtrMult x ATR (never inside the broker stop      |
//|   level), TP = InpRR x SL, break-even at 1R, ATR trail from 1.5R,|
//|   and the position closes when the line flips to the opposite    |
//|   colour (then the opposite entry is checked on the same bar).   |
//|                                                                  |
//| SIZE: InpRiskPercent of equity lost at the stop (default 1.0%),  |
//|   capped by InpMaxLots and by InpMaxMarginUsePct of free margin. |
//|   LEVERAGE IS AN ACCOUNT SETTING (change it with your broker);   |
//|   a higher leverage lowers the margin per lot, so the margin cap |
//|   binds later and the risk-% size can actually be placed.        |
//|                                                                  |
//| WHY THE COURSE EA DID NOT TRADE ON GOLD: 46 x _Point = 0.46 USD  |
//| stop (inside the spread/stop level -> rejected), FOK filling     |
//| hard-coded (unsupported on many gold symbols), and               |
//| PositionsTotal() counted every position on the account.          |
//|                                                                  |
//| SAFETY: InpRunMode defaults BACKTEST (live chart: logs, no orders).|
//| The Strategy Tester always simulates. Arm live yourself.         |
//|                                                                  |
//| INSTALL: MQL5\Indicators\TSI_Trend.mq5 (compile it first), this  |
//| file in MQL5\Experts\. NOT compiled on the authoring Mac.        |
//+------------------------------------------------------------------+
#property copyright "MT5-SetUp"
#property link      ""
#property version   "2.00"
#property description "Trades TSI_Trend colour flips (crossovers) with filled-candle + EMA 9/21/48 + ADX confirmation, ATR stop, RR target, break-even + trail, risk-% sizing. Default DRY RUN."
#property tester_indicator "TSI_CD.ex5"
#property tester_indicator "TSI_Trend.ex5"

#include <Trade\Trade.mqh>

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,   // Fixed lots
   LOT_RISK_PERCENT = 1    // % of equity at risk
  };
enum ENUM_RUN_MODE
  {
   RUN_BACKTEST = 0,   // Backtest / signals only (no live orders)
   RUN_LIVE     = 1    // LIVE: send real orders
  };
enum ENUM_EMA_FILTER
  {
   EMA_FILTER_OFF       = 0,   // Off
   EMA_CLOSE_BEYOND_ALL = 1,   // Close above all 3 (buy) / below all 3 (sell)
   EMA_FULL_STACK       = 2    // ...and EMAs ordered 9>21>48 / 9<21<48
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== TSI trend line (must match the TSI_Trend indicator) ==="
input int             InpTsiEma1         = 25;        // TSI first smoothing
input int             InpTsiEma2         = 13;        // TSI second smoothing
input int             InpTsiSignal       = 10;        // Signal line period
input ENUM_MA_METHOD  InpTsiSignalMode   = MODE_EMA;  // Signal line method

input group "=== Entry: crossover + confirmation ==="
input int             InpCrossLookback   = 1;         // 1 = trade ONLY on the crossover candle itself (exact). 2-3 = allow a late confirmation candle
input bool            InpRequireFilledCandle = true;  // Confirmation candle needs a solid body in the trade direction
input double          InpMinBodyFrac     = 0.50;      // Body must be >= this fraction of the candle's high-low range
input ENUM_EMA_FILTER InpEmaFilter       = EMA_CLOSE_BEYOND_ALL; // EMA 9/21/48 rule
input int             InpEmaFast         = 9;         // Fast EMA
input int             InpEmaMid          = 21;        // Mid EMA
input int             InpEmaSlow         = 48;        // Slow EMA
input int             InpAdxPeriod       = 14;        // ADX period
input double          InpMinADX          = 20.0;      // Min ADX (0 = off)
input int             InpMaxSpreadPoints = 0;         // Max spread in points (0 = off) - set this for live gold
input bool            InpCloseOnOppositeCross = true; // Close the position when the line flips to the opposite colour

input group "=== Stops / targets ==="
input int             InpAtrPeriod       = 14;        // ATR period
input double          InpSlAtrMult       = 1.5;       // Stop = this x ATR
input double          InpRR              = 2.0;       // Take-profit = this x stop distance
input bool            InpUseBreakEven    = true;      // Move stop to break-even
input double          InpBreakEvenAtR    = 1.0;       // ...once this many R in profit
input double          InpBreakEvenLockR  = 0.1;       // ...locking this many R
input bool            InpUseTrailing     = true;      // ATR trailing stop
input double          InpTrailStartR     = 1.5;       // Start trailing at this many R
input double          InpTrailAtrMult    = 1.5;       // Trail this x ATR behind price

input group "=== Position size / leverage ==="
input ENUM_LOT_MODE   InpLotMode         = LOT_RISK_PERCENT; // Sizing mode
input double          InpFixedLots       = 0.05;      // Lots when LOT_FIXED
input double          InpRiskPercent     = 1.0;       // % of equity lost if the stop is hit (LOT_RISK_PERCENT)
input double          InpMaxLots         = 1.00;      // Hard lot cap
input double          InpMaxMarginUsePct = 50.0;      // Never use more than this % of free margin on one trade
input bool            InpMinLotFallback  = true;      // If the risk-% size is below the minimum lot, trade the minimum lot...
input double          InpMaxRiskPctAtMinLot = 3.0;    // ...but only if that minimum lot risks <= this % of equity

input group "=== Guards ==="
input int             InpMaxPositions    = 1;         // Max open positions (this EA, this symbol)
input double          InpDailyLossPct    = 3.0;       // Stop new trades after this % equity loss today (0 = off)
input bool            InpSessionEnabled  = false;     // Restrict entries to the window below (server time)
input string          InpSessStart       = "01:00";   // Window start HH:MM
input string          InpSessEnd         = "23:00";   // Window end HH:MM

input group "=== Execution ==="
input ENUM_RUN_MODE   InpRunMode         = RUN_BACKTEST; // BACKTEST = Strategy Tester trades, live chart only logs signals. LIVE = send real orders on the live chart
input bool            InpShowHelperIndicators = false; // Show EMA 9/21/48, ADX and ATR on the tester chart (they are always used for the rules)
input ulong           InpMagic           = 20260928;  // Magic number
input int             InpDeviationPoints = 30;        // Max slippage (points)
input string          InpComment         = "TSI_Trend_v2"; // Order comment
input bool            InpJournal         = true;      // Journal to Common\Files\aman_sc_v2_trades.csv
input bool            InpVerboseLog      = false;     // Print why each bar did not trade

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade   g_trade;
int      g_hCd = INVALID_HANDLE;       // course TSI_CD panel (histogram + blue line + dotted signal + drawn lines)
int      g_hTsi = INVALID_HANDLE, g_hEmaF = INVALID_HANDLE, g_hEmaM = INVALID_HANDLE, g_hEmaS = INVALID_HANDLE;
int      g_hAdx = INVALID_HANDLE, g_hAtr = INVALID_HANDLE;
datetime g_lastBar = 0;
datetime g_lastTradedFlip = 0;      // bar time of the crossover already traded
datetime g_dayStart = 0;
double   g_dayStartEquity = 0.0;
int      g_sessStart = 0, g_sessEnd = 0;
bool     g_selfTestOk = true;
int      g_testsRun = 0, g_testsFailed = 0;
int      g_tradesOpened = 0;
int      g_crossesSeen  = 0;
string   g_rejectReason[];
long     g_rejectCount[];

//+------------------------------------------------------------------+
//| PURE helpers (fixtured in RunSelfTests)                          |
//+------------------------------------------------------------------+
bool Near(const double a, const double b) { return(MathAbs(a - b) < 1e-8); }

// col[0] = colour of the last CLOSED bar, col[1] the bar before, ...
// (0 = green/bull, 1 = red/bear). Returns +1 / -1 if the line flipped INTO
// its current colour within the last `lookback` closed bars (and stayed),
// with flipIdx = index in col[] of the first bar of the new colour. 0 = none.
int RecentFlip(const double &col[], const int count, const int lookback, int &flipIdx)
  {
   flipIdx = -1;
   if(count < 2 || lookback < 1) return(0);
   int cur = (int)MathRound(col[0]);
   int last = MathMin(lookback, count - 1);
   for(int k = 0; k < last; k++)
     {
      if((int)MathRound(col[k + 1]) != cur)
        { flipIdx = k; return(cur == 0 ? 1 : -1); }
      // col[k+1] still the current colour -> keep walking back
     }
   return(0);
  }

// Solid body in the trade direction covering >= minFrac of the range.
bool FilledCandle(const bool isBuy, const double o, const double h, const double l, const double c, const double minFrac)
  {
   double range = h - l;
   if(range <= 0.0) return(false);
   double body = isBuy ? c - o : o - c;
   if(body <= 0.0) return(false);
   return(body >= minFrac * range - 1e-12);
  }

bool EmaFilterPass(const ENUM_EMA_FILTER mode, const bool isBuy, const double c,
                   const double f, const double m, const double s)
  {
   if(mode == EMA_FILTER_OFF) return(true);
   bool beyond = isBuy ? (c > f && c > m && c > s) : (c < f && c < m && c < s);
   if(mode == EMA_CLOSE_BEYOND_ALL) return(beyond);
   bool stacked = isBuy ? (f > m && m > s) : (f < m && m < s);
   return(beyond && stacked);
  }

double StopDistance(const double atr, const double mult, const double minDist)
  {
   return(MathMax(atr * mult, minDist));
  }

int StepDigits(const double step)
  {
   int d = 0; double p = step;
   while(d < 8 && MathAbs(p - MathRound(p)) > 1e-9) { p *= 10.0; d++; }
   return(d);
  }

// Round DOWN to the step, cap at maxLots; 0 if below the broker minimum (never round a trade UP).
double NormalizeLotsDown(const double lots, const double step, const double minL, const double maxL)
  {
   if(step <= 0.0 || lots <= 0.0) return(0.0);
   double v = MathFloor(lots / step + 1e-9) * step;
   if(maxL > 0.0 && v > maxL) v = MathFloor(maxL / step + 1e-9) * step;
   if(v < minL - 1e-12) return(0.0);
   return(NormalizeDouble(v, StepDigits(step)));
  }

double LotsForRisk(const double riskMoney, const double lossPerLot)
  {
   if(riskMoney <= 0.0 || lossPerLot <= 0.0) return(0.0);
   return(riskMoney / lossPerLot);
  }

// Largest lots whose margin stays within maxUsePct of free margin.
double MarginCapLots(const double marginPerLot, const double freeMargin, const double maxUsePct)
  {
   if(marginPerLot <= 0.0 || freeMargin <= 0.0 || maxUsePct <= 0.0) return(0.0);
   return(freeMargin * maxUsePct / 100.0 / marginPerLot);
  }

bool ReachedR(const double favourable, const double riskDist, const double r)
  {
   if(riskDist <= 0.0) return(false);
   return(favourable >= r * riskDist);
  }
double BreakEvenStop(const bool isBuy, const double entry, const double riskDist, const double lockR)
  {
   return(isBuy ? entry + lockR * riskDist : entry - lockR * riskDist);
  }
double TrailStop(const bool isBuy, const double price, const double atr, const double mult)
  {
   return(isBuy ? price - mult * atr : price + mult * atr);
  }
bool StopImproves(const bool isBuy, const double cur, const double cand, const double minStep)
  {
   if(cand <= 0.0) return(false);
   if(cur <= 0.0) return(true);
   return(isBuy ? cand >= cur + minStep : cand <= cur - minStep);
  }

int ParseHHMM(const string s)
  {
   if(StringLen(s) != 5 || StringGetCharacter(s, 2) != ':') return(-1);
   int hh = (int)StringToInteger(StringSubstr(s, 0, 2));
   int mm = (int)StringToInteger(StringSubstr(s, 3, 2));
   if(hh < 0 || hh > 23 || mm < 0 || mm > 59) return(-1);
   return(hh * 60 + mm);
  }
bool InWindowMins(const int mins, const int start, const int end)
  {
   if(start == end) return(true);
   if(start < end)  return(mins >= start && mins < end);
   return(mins >= start || mins < end);
  }

//+------------------------------------------------------------------+
//| Readers / guards                                                 |
//+------------------------------------------------------------------+
bool LiveArmed() { return(InpRunMode == RUN_LIVE); }
bool SendOrdersEnabled() { return(LiveArmed() || (bool)MQLInfoInteger(MQL_TESTER)); }

bool CopySeries(const int handle, const int buffer, const int start, const int count, double &arr[])
  {
   ArraySetAsSeries(arr, true);
   return(CopyBuffer(handle, buffer, start, count, arr) == count);
  }

void CountReject(const string reason)
  {
   int n = ArraySize(g_rejectReason);
   for(int i = 0; i < n; i++)
      if(g_rejectReason[i] == reason) { g_rejectCount[i]++; if(InpVerboseLog) PrintFormat("no trade: %s", reason); return; }
   ArrayResize(g_rejectReason, n + 1); ArrayResize(g_rejectCount, n + 1);
   g_rejectReason[n] = reason; g_rejectCount[n] = 1;
   if(InpVerboseLog) PrintFormat("no trade: %s", reason);
  }
void PrintRejectTally()
  {
   int n = ArraySize(g_rejectReason);
   Print("=== v2 reject tally (closed bars that did not trade) ===");
   for(int i = 0; i < n; i++) PrintFormat("  %-24s %I64d", g_rejectReason[i], g_rejectCount[i]);
  }

int CountOurPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
     }
   return(n);
  }

// Persisted state (terminal global variables) so a restart or input change never
// re-trades a crossover, never resets the daily-loss baseline, and keeps each
// trade's original 1R. Dry run uses its own namespace.
string GvName(const string k)
  {
   return(StringFormat("SCV2_%s%I64u_%s_%s", SendOrdersEnabled() ? "" : "DRY_", InpMagic, _Symbol, k));
  }
double GvGet(const string k, const double def)
  {
   string n = GvName(k);
   return(GlobalVariableCheck(n) ? GlobalVariableGet(n) : def);
  }
void GvSet(const string k, const double v) { GlobalVariableSet(GvName(k), v); GlobalVariablesFlush(); }

void RememberRisk(const ulong ticket, const double slDist)
  {
   if(ticket > 0 && slDist > 0.0) GvSet("R" + IntegerToString((long)ticket), slDist);
  }
void MarkFlipTraded(const datetime flipTime)
  {
   g_lastTradedFlip = flipTime;
   GvSet("lastFlip", (double)flipTime);
  }

void UpdateDay()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime d = StructToTime(dt);
   if(d == g_dayStart) return;
   g_dayStart = d;
   if((datetime)GvGet("dayStart", 0.0) == d)
      g_dayStartEquity = GvGet("dayEq", AccountInfoDouble(ACCOUNT_EQUITY));   // same day after a restart: keep the baseline
   else
     {
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      GvSet("dayStart", (double)d);
      GvSet("dayEq", g_dayStartEquity);
     }
  }
bool DailyLossHit()
  {
   if(InpDailyLossPct <= 0.0 || g_dayStartEquity <= 0.0) return(false);
   return((g_dayStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_dayStartEquity * 100.0 >= InpDailyLossPct);
  }
bool InSession()
  {
   if(!InpSessionEnabled) return(true);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return(InWindowMins(dt.hour * 60 + dt.min, g_sessStart, g_sessEnd));
  }

void Journal(const string action, const bool isBuy, const double lots, const double price,
             const double sl, const double tp, const string info)
  {
   if(!InpJournal) return;
   int h = FileOpen("aman_sc_v2_trades.csv", FILE_COMMON | FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   if(FileSize(h) == 0) FileWrite(h, "time", "symbol", "mode", "action", "side", "lots", "price", "sl", "tp", "info");
   FileSeek(h, 0, SEEK_END);
   string mode = (bool)MQLInfoInteger(MQL_TESTER) ? "TESTER" : (LiveArmed() ? "LIVE" : "DRY_RUN");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), _Symbol, mode, action, isBuy ? "BUY" : "SELL",
             DoubleToString(lots, 2), DoubleToString(price, _Digits), DoubleToString(sl, _Digits),
             DoubleToString(tp, _Digits), info);
   FileClose(h);
  }

bool HasOppositePosition(const bool isBuy)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      bool posBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(posBuy != isBuy) return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Close positions against the line's colour                        |
//+------------------------------------------------------------------+
void CloseAgainst(const int stateDir)
  {
   if(!SendOrdersEnabled()) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if((isBuy && stateDir < 0) || (!isBuy && stateDir > 0))
        {
         double vol = PositionGetDouble(POSITION_VOLUME);
         if(g_trade.PositionClose(t, InpDeviationPoints) &&
            (g_trade.ResultRetcode() == TRADE_RETCODE_DONE || g_trade.ResultRetcode() == TRADE_RETCODE_DONE_PARTIAL))
           {
            PrintFormat("CLOSE %s %.2f on opposite crossover", isBuy ? "BUY" : "SELL", vol);
            Journal("CLOSE_OPPOSITE_CROSS", isBuy, vol, g_trade.ResultPrice(), 0.0, 0.0, "");
           }
         else
            PrintFormat("close %I64u failed rc=%u %s", t, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Entry logic on each new closed bar                               |
//+------------------------------------------------------------------+
// Returns false only when data is not ready, so the bar is retried on the next tick.
bool EvaluateBar()
  {
   int need = InpCrossLookback + 1;
   double col[];
   if(!CopySeries(g_hTsi, 3, 1, need, col)) { CountReject("TSI_NOT_READY"); return(false); }
   int stateDir = ((int)MathRound(col[0]) == 0) ? 1 : -1;

   if(InpCloseOnOppositeCross) CloseAgainst(stateDir);

   int flipIdx = -1;
   int dir = RecentFlip(col, need, InpCrossLookback, flipIdx);
   if(dir == 0) return(true);   // no crossover on this candle (normal; not counted as a skip)
   datetime flipTime = iTime(_Symbol, _Period, flipIdx + 1);
   if(flipTime == 0) { CountReject("NO_BAR_TIME"); return(false); }
   if(flipTime == g_lastTradedFlip) { CountReject("CROSS_ALREADY_TRADED"); return(true); }
   g_crossesSeen++;

   if(!g_selfTestOk)                 { CountReject("SELFTEST_FAILED");  return(true); }
   if(DailyLossHit())                { CountReject("DAILY_LOSS_HALT");  return(true); }
   if(!InSession())                  { CountReject("OUTSIDE_SESSION");  return(true); }
   if(CountOurPositions() >= InpMaxPositions) { CountReject("POSITION_LIMIT"); return(true); }

   bool isBuy = (dir > 0);
   if(HasOppositePosition(isBuy)) { CountReject("OPPOSITE_POSITION_OPEN"); return(true); }   // never hold BUY and SELL together
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, _Period, 1, 1, r) != 1) { CountReject("NO_RATES"); return(false); }
   if(InpRequireFilledCandle && !FilledCandle(isBuy, r[0].open, r[0].high, r[0].low, r[0].close, InpMinBodyFrac))
     { CountReject("CANDLE_NOT_FILLED"); return(true); }

   double ef[], em[], es[], adx[], atr[];
   if(!CopySeries(g_hEmaF, 0, 1, 1, ef) || !CopySeries(g_hEmaM, 0, 1, 1, em) || !CopySeries(g_hEmaS, 0, 1, 1, es) ||
      !CopySeries(g_hAdx, 0, 1, 1, adx) || !CopySeries(g_hAtr, 0, 1, 1, atr))
     { CountReject("INDICATORS_NOT_READY"); return(false); }
   if(!EmaFilterPass(InpEmaFilter, isBuy, r[0].close, ef[0], em[0], es[0])) { CountReject("EMA_RULE"); return(true); }
   if(InpMinADX > 0.0 && adx[0] < InpMinADX) { CountReject("ADX_TOO_LOW"); return(true); }
   if(atr[0] <= 0.0) { CountReject("ATR_ZERO"); return(true); }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) { CountReject("NO_TICK"); return(true); }
   double spreadPts = (tick.ask - tick.bid) / _Point;
   if(InpMaxSpreadPoints > 0 && spreadPts > InpMaxSpreadPoints) { CountReject("SPREAD_TOO_WIDE"); return(true); }

   // Stop never inside the broker's stop level (+ spread + 2 points of room).
   double stopsLvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double minDist  = stopsLvl + (tick.ask - tick.bid) + 2.0 * _Point;
   double slDist   = StopDistance(atr[0], InpSlAtrMult, minDist);
   double price    = isBuy ? tick.ask : tick.bid;
   double sl = NormalizeDouble(isBuy ? price - slDist : price + slDist, _Digits);
   double tp = NormalizeDouble(isBuy ? price + InpRR * slDist : price - InpRR * slDist, _Digits);
   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   // Size.
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLots);
   double raw  = InpFixedLots;
   double riskMoney = 0.0;
   if(InpLotMode == LOT_RISK_PERCENT)
     {
      double lossPerLot = 0.0;
      if(!OrderCalcProfit(type, _Symbol, 1.0, price, sl, lossPerLot)) { CountReject("CALC_PROFIT_FAIL"); return(true); }
      riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
      raw = LotsForRisk(riskMoney, MathAbs(lossPerLot));
     }
   double marginPerLot = 0.0;
   if(!OrderCalcMargin(type, _Symbol, 1.0, price, marginPerLot) || marginPerLot <= 0.0)
     { CountReject("CALC_MARGIN_FAIL"); return(true); }   // fail closed: never size without the margin cap
   raw = MathMin(raw, MarginCapLots(marginPerLot, AccountInfoDouble(ACCOUNT_MARGIN_FREE), InpMaxMarginUsePct));
   double lots = NormalizeLotsDown(raw, step, minL, maxL);
   if(lots <= 0.0 && InpMinLotFallback && InpLotMode == LOT_RISK_PERCENT)
     {
      // Risk-% size is below the broker minimum (small account or a wide ATR stop).
      // Take the MINIMUM lot only if its real risk stays within InpMaxRiskPctAtMinLot.
      double lossMin = 0.0;
      if(OrderCalcProfit(type, _Symbol, minL, price, sl, lossMin))
        {
         double riskPctMin = MathAbs(lossMin) / AccountInfoDouble(ACCOUNT_EQUITY) * 100.0;
         bool marginOk = (minL <= MarginCapLots(marginPerLot, AccountInfoDouble(ACCOUNT_MARGIN_FREE), InpMaxMarginUsePct));
         if(riskPctMin <= InpMaxRiskPctAtMinLot && marginOk)
           { lots = NormalizeLotsDown(minL, step, minL, maxL); riskMoney = MathAbs(lossMin); }
         else
           { CountReject(marginOk ? "MIN_LOT_RISK_TOO_HIGH" : "NO_MARGIN_FOR_MIN_LOT"); return(true); }
        }
     }
   if(lots <= 0.0) { CountReject("LOT_BELOW_MIN"); return(true); }

   string info = StringFormat("cross_bar=%s adx=%.1f atr=%.2f risk=%.2f", TimeToString(flipTime, TIME_DATE | TIME_MINUTES),
                              adx[0], atr[0], riskMoney);
   MarkFlipTraded(flipTime);   // one trade per crossover, even if the send fails (persisted across restarts)

   if(!SendOrdersEnabled())
     {
      PrintFormat("DRY_RUN %s %.2f %s SL=%.*f TP=%.*f (%s)", isBuy ? "BUY" : "SELL", lots, _Symbol, _Digits, sl, _Digits, tp, info);
      Journal("DRY_RUN", isBuy, lots, price, sl, tp, info);
      return(true);
     }
   bool sent = isBuy ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, InpComment)
                     : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, InpComment);
   uint rc = g_trade.ResultRetcode();
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED))
     {
      PrintFormat("ORDER REJECTED %s %.2f rc=%u %s (%s)", isBuy ? "BUY" : "SELL", lots, rc, g_trade.ResultRetcodeDescription(), info);
      Journal("REJECTED", isBuy, lots, price, sl, tp, IntegerToString(rc) + " " + info);
      Alert(isBuy ? "A buy trade could not be placed -Error: " : "A sell order could not be placed. Error: ", rc);
      return(true);
     }
   PrintFormat("%s %.2f %s @ %.*f SL=%.*f TP=%.*f (%s)", isBuy ? "BUY" : "SELL", lots, _Symbol,
               _Digits, g_trade.ResultPrice(), _Digits, sl, _Digits, tp, info);
   Journal("OPEN", isBuy, lots, g_trade.ResultPrice(), sl, tp, info);
   g_tradesOpened++;
   Alert(isBuy ? "A buy order has been successfully placed with ticket# :" : "A sell order has been successfully placed with ticket# :",
         g_trade.ResultOrder(), "!!");   // same Journal line as the course
   RememberRisk(g_trade.ResultOrder(), slDist);
   return(true);
  }

//+------------------------------------------------------------------+
//| Break-even + ATR trailing (every tick)                           |
//+------------------------------------------------------------------+
void ManageOpenTrades()
  {
   if(!SendOrdersEnabled() || (!InpUseBreakEven && !InpUseTrailing)) return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double atr[];
   if(!CopySeries(g_hAtr, 0, 1, 1, atr) || atr[0] <= 0.0) return;
   double stopsLvl  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double freezeLvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
   double minStep   = MathMax(10.0 * _Point, 0.10 * atr[0]);   // move the stop in 0.1-ATR steps, not every tick

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSl = PositionGetDouble(POSITION_SL);
      double curTp = PositionGetDouble(POSITION_TP);
      double price0 = isBuy ? tick.bid : tick.ask;
      // Broker freeze zone: SL/TP cannot be modified this close to price.
      if(freezeLvl > 0.0 && ((curSl > 0.0 && MathAbs(price0 - curSl) <= freezeLvl) ||
                             (curTp > 0.0 && MathAbs(curTp - price0) <= freezeLvl))) continue;
      // Original 1R = the stop distance stored at entry; fallback |TP-entry|/RR.
      double riskDist = GvGet("R" + IntegerToString((long)t), 0.0);
      if(riskDist <= 0.0)
        {
         if(curTp <= 0.0 || InpRR <= 0.0) continue;
         riskDist = MathAbs(curTp - entry) / InpRR;
        }
      double price = isBuy ? tick.bid : tick.ask;
      double fav   = isBuy ? price - entry : entry - price;

      double cand = 0.0;
      if(InpUseBreakEven && ReachedR(fav, riskDist, InpBreakEvenAtR))
         cand = BreakEvenStop(isBuy, entry, riskDist, InpBreakEvenLockR);
      if(InpUseTrailing && ReachedR(fav, riskDist, InpTrailStartR))
        {
         double tr = TrailStop(isBuy, price, atr[0], InpTrailAtrMult);
         cand = (cand <= 0.0) ? tr : (isBuy ? MathMax(cand, tr) : MathMin(cand, tr));
        }
      if(cand <= 0.0) continue;
      cand = NormalizeDouble(cand, _Digits);
      if(!StopImproves(isBuy, curSl, cand, minStep)) continue;
      if(isBuy && cand >= price - stopsLvl) continue;
      if(!isBuy && cand <= price + stopsLvl) continue;
      if(!g_trade.PositionModify(t, cand, curTp))
         PrintFormat("modify %I64u failed rc=%u", t, g_trade.ResultRetcode());
     }
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
   int fi;
   double upNow[]   = {0, 1, 1, 1};   // turned green on the bar just closed
   double upOld[]   = {0, 0, 0, 1};   // turned green 3 bars ago, still green
   double upStale[] = {0, 0, 0, 0};   // green for a long time, no recent cross
   double dnNow[]   = {1, 0, 0, 0};
   Check(RecentFlip(upNow, 4, 3, fi) == 1 && fi == 0,   "green flip on last bar -> BUY, idx 0");
   Check(RecentFlip(upOld, 4, 3, fi) == 1 && fi == 2,   "green flip 3 bars back -> BUY, idx 2");
   Check(RecentFlip(upOld, 4, 1, fi) == 0,              "lookback 1 ignores an older flip");
   Check(RecentFlip(upStale, 4, 3, fi) == 0,            "no flip in the window -> no trade");
   Check(RecentFlip(dnNow, 4, 3, fi) == -1 && fi == 0,  "red flip on last bar -> SELL");

   Check(FilledCandle(true, 100.0, 101.2, 99.9, 101.0, 0.5),   "buy: body 1.0 of range 1.3 -> filled");
   Check(!FilledCandle(true, 100.0, 101.0, 99.0, 100.2, 0.5),  "buy: body 0.2 of range 2.0 -> doji, not filled");
   Check(!FilledCandle(true, 101.0, 101.5, 99.5, 100.0, 0.5),  "buy: bearish candle -> not filled");
   Check(FilledCandle(false, 101.0, 101.1, 99.8, 100.0, 0.5),  "sell: body 1.0 of range 1.3 -> filled");

   Check(EmaFilterPass(EMA_CLOSE_BEYOND_ALL, true, 105.0, 104.0, 103.0, 102.0),  "buy close above all 3 EMAs");
   Check(!EmaFilterPass(EMA_CLOSE_BEYOND_ALL, true, 103.5, 104.0, 103.0, 102.0), "buy close below fast EMA -> reject");
   Check(EmaFilterPass(EMA_CLOSE_BEYOND_ALL, true, 105.0, 102.0, 103.0, 104.0),  "beyond-all ignores EMA order");
   Check(!EmaFilterPass(EMA_FULL_STACK, true, 105.0, 102.0, 103.0, 104.0),       "full stack needs 9>21>48");
   Check(EmaFilterPass(EMA_FULL_STACK, false, 99.0, 100.0, 101.0, 102.0),        "sell full stack below 9<21<48");
   Check(EmaFilterPass(EMA_FILTER_OFF, true, 1.0, 5.0, 5.0, 5.0),                "filter off passes");

   Check(Near(StopDistance(4.0, 1.5, 0.5), 6.0), "stop = 1.5 x ATR 4 = 6");
   Check(Near(StopDistance(0.2, 1.5, 0.5), 0.5), "stop floored at broker minimum");

   // Gold: 1 lot = 100 oz, stop 6.00 -> 600 USD/lot. 1% of 10000 = 100 USD -> 0.1666 -> 0.16.
   Check(Near(NormalizeLotsDown(LotsForRisk(100.0, 600.0), 0.01, 0.01, 1.0), 0.16), "1% of 10k on a 6.00 stop -> 0.16 lots");
   Check(Near(NormalizeLotsDown(LotsForRisk(5.0, 600.0), 0.01, 0.01, 1.0), 0.0),    "risk too small for min lot -> skip (no round-up)");
   Check(Near(NormalizeLotsDown(5.0, 0.01, 0.01, 1.0), 1.0),                        "capped at InpMaxLots");
   Check(Near(MarginCapLots(1000.0, 10000.0, 50.0), 5.0), "50% of 10k free / 1000 per lot -> 5 lots max");

   Check(ReachedR(6.0, 6.0, 1.0) && !ReachedR(5.9, 6.0, 1.0), "1R reached exactly at 6.0");
   Check(Near(BreakEvenStop(true, 2000.0, 6.0, 0.1), 2000.6), "buy BE = entry + 0.1R");
   Check(Near(TrailStop(false, 1990.0, 4.0, 1.5), 1996.0),    "sell trail = price + 1.5 ATR");
   Check(StopImproves(true, 1994.0, 1995.0, 0.1) && !StopImproves(true, 1995.0, 1994.0, 0.1), "buy stop only moves up");

   Check(ParseHHMM("01:00") == 60 && ParseHHMM("9:00") == -1, "HH:MM parsing");
   Check(InWindowMins(60, 60, 1380) && !InWindowMins(1380, 60, 1380), "session window [start, end)");

   g_selfTestOk = (g_testsFailed == 0);
   PrintFormat("SELFTEST SUMMARY: %d checks, %d failed%s", g_testsRun, g_testsFailed,
               g_selfTestOk ? " - all green" : " - EA WILL NOT TRADE");
  }

//+------------------------------------------------------------------+
//| Lifecycle                                                        |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_sessStart = ParseHHMM(InpSessStart);
   g_sessEnd   = ParseHHMM(InpSessEnd);
   if(g_sessStart < 0 || g_sessEnd < 0) { Print("OnInit failed: session times must be HH:MM"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpCrossLookback < 1 || InpRR <= 0.0 || InpSlAtrMult <= 0.0 || InpMaxPositions < 1 ||
      InpMinBodyFrac < 0.0 || InpMinBodyFrac > 1.0 || InpRiskPercent <= 0.0 || InpFixedLots <= 0.0 ||
      InpMaxLots <= 0.0 || InpMaxMarginUsePct <= 0.0 || InpMaxMarginUsePct > 100.0 || InpDeviationPoints < 0)
     { Print("OnInit failed: an input is out of range (lookback>=1, RR>0, ATR mult>0, body 0..1, risk>0, margin 0..100)"); return(INIT_PARAMETERS_INCORRECT); }

   // Created FIRST so the tester shows it as the first panel, like the course chart.
   g_hCd = iCustom(_Symbol, _Period, "TSI_CD", InpTsiEma1, InpTsiEma2, InpTsiSignal, InpTsiSignalMode);
   if(g_hCd == INVALID_HANDLE)
     {
      PrintFormat("OnInit failed: cannot load TSI_CD (error %d). Put TSI_CD.mq5 in MQL5\\Indicators\\ (NOT Scripts) and compile it.", GetLastError());
      return(INIT_FAILED);
     }
   g_hTsi = iCustom(_Symbol, _Period, "TSI_Trend", InpTsiEma1, InpTsiEma2, InpTsiSignal, InpTsiSignalMode);
   if(g_hTsi == INVALID_HANDLE)
     {
      PrintFormat("OnInit failed: cannot load TSI_Trend (error %d). Put TSI_Trend.mq5 in MQL5\\Indicators\\ (NOT Scripts) and compile it.", GetLastError());
      return(INIT_FAILED);
     }
   // Rule indicators: used for the checks, hidden from the tester chart unless asked (only the two TSI panels show).
   TesterHideIndicators(!InpShowHelperIndicators);
   g_hEmaF = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaM = iMA(_Symbol, _Period, InpEmaMid,  0, MODE_EMA, PRICE_CLOSE);
   g_hEmaS = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAdx  = iADX(_Symbol, _Period, InpAdxPeriod);
   g_hAtr  = iATR(_Symbol, _Period, InpAtrPeriod);
   TesterHideIndicators(false);
   if(g_hEmaF == INVALID_HANDLE || g_hEmaM == INVALID_HANDLE || g_hEmaS == INVALID_HANDLE ||
      g_hAdx == INVALID_HANDLE || g_hAtr == INVALID_HANDLE)
     { Print("OnInit failed: EMA/ADX/ATR handle"); return(INIT_FAILED); }

   // Show the trend line on a live chart (the tester adds it by itself).
   if(!(bool)MQLInfoInteger(MQL_TESTER))
     {
      if(ChartWindowFind(0, "TSI_CD") < 0)   // add once, never stack copies on re-init
         ChartIndicatorAdd(0, (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL), g_hCd);
      string shortName = StringFormat("TSI(%d,%d,%d)", InpTsiEma1, InpTsiEma2, InpTsiSignal);
      if(ChartWindowFind(0, shortName) < 0)
         ChartIndicatorAdd(0, (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL), g_hTsi);
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);   // broker-supported fill mode (the course's hard-coded FOK is often rejected on gold)

   RunSelfTests();
   if((bool)MQLInfoInteger(MQL_TESTER)) GlobalVariablesDeleteAll(GvName(""));   // each tester run starts clean
   g_lastTradedFlip = (datetime)GvGet("lastFlip", 0.0);
   g_lastBar = iTime(_Symbol, _Period, 0);   // first evaluation waits for the NEXT bar open, never mid-bar
   g_dayStart = 0;
   UpdateDay();
   PrintFormat("=== aman_sc v2 | %s %s | mode=%s | TSI(%d,%d,%d) lookback %d | filled candle %s (body>=%.2f) | EMA rule %s %d/%d/%d | ADX>=%.1f ===",
               _Symbol, EnumToString(_Period),
               (bool)MQLInfoInteger(MQL_TESTER) ? "STRATEGY TESTER" : (LiveArmed() ? "*** LIVE ORDERS ***" : "BACKTEST mode on a live chart: signals logged, NO orders"),
               InpTsiEma1, InpTsiEma2, InpTsiSignal, InpCrossLookback, InpRequireFilledCandle ? "on" : "off", InpMinBodyFrac,
               EnumToString(InpEmaFilter), InpEmaFast, InpEmaMid, InpEmaSlow, InpMinADX);
   PrintFormat("stop %.2f x ATR%d | TP %.2f R | BE %s at %.1fR | trail %s from %.1fR (%.1f ATR) | size %s %.2f%% (fixed %.2f) max %.2f lots, <=%.0f%% free margin | account leverage 1:%I64d",
               InpSlAtrMult, InpAtrPeriod, InpRR, InpUseBreakEven ? "on" : "off", InpBreakEvenAtR,
               InpUseTrailing ? "on" : "off", InpTrailStartR, InpTrailAtrMult, EnumToString(InpLotMode),
               InpRiskPercent, InpFixedLots, InpMaxLots, InpMaxMarginUsePct, AccountInfoInteger(ACCOUNT_LEVERAGE));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   PrintRejectTally();
   if(g_hCd   != INVALID_HANDLE) IndicatorRelease(g_hCd);
   if(g_hTsi  != INVALID_HANDLE) IndicatorRelease(g_hTsi);
   if(!(bool)MQLInfoInteger(MQL_TESTER)) Comment("");   // keep the stats on the tester chart after the run
   if(g_hEmaF != INVALID_HANDLE) IndicatorRelease(g_hEmaF);
   if(g_hEmaM != INVALID_HANDLE) IndicatorRelease(g_hEmaM);
   if(g_hEmaS != INVALID_HANDLE) IndicatorRelease(g_hEmaS);
   if(g_hAdx  != INVALID_HANDLE) IndicatorRelease(g_hAdx);
   if(g_hAtr  != INVALID_HANDLE) IndicatorRelease(g_hAtr);
  }

// Top-left chart text like the course chart: TSI_CD histogram, main line, signal line
// (last closed bar), plus the bull/bear state of the TSI line.
// Top-N skip reasons, most frequent first, e.g. "EMA_RULE 812, NO_RECENT_CROSS 640".
string TopRejects(const int n)
  {
   int total = ArraySize(g_rejectReason);
   if(total == 0) return("none yet");
   bool used[];
   ArrayResize(used, total);
   ArrayInitialize(used, false);
   string out = "";
   for(int k = 0; k < n && k < total; k++)
     {
      int best = -1;
      for(int i = 0; i < total; i++)
         if(!used[i] && (best < 0 || g_rejectCount[i] > g_rejectCount[best])) best = i;
      if(best < 0) break;
      used[best] = true;
      out += (k > 0 ? ", " : "") + g_rejectReason[best] + " " + IntegerToString(g_rejectCount[best]);
     }
   return(out);
  }

void ShowCourseComment()
  {
   double cd[], ml[], sl[], col[];
   if(!CopySeries(g_hCd, 0, 1, 1, cd) || !CopySeries(g_hCd, 2, 1, 1, ml) || !CopySeries(g_hCd, 3, 1, 1, sl)) return;
   string state = CopySeries(g_hTsi, 3, 1, 1, col) ? (((int)MathRound(col[0]) == 0) ? "BULLISH (blue)" : "BEARISH (red)") : "-";
   Comment(StringFormat("cdbuffer = %.2f, mlinebuffer = %.2f, slinebuffer = %.2f | TSI line: %s | positions: %d | mode: %s\ncrossovers: %d | trades opened: %d | crossovers skipped because: %s",
                        cd[0], ml[0], sl[0], state, CountOurPositions(),
                        (bool)MQLInfoInteger(MQL_TESTER) ? "BACKTEST" : (LiveArmed() ? "LIVE" : "BACKTEST (live chart, no orders)"),
                        g_crossesSeen, g_tradesOpened, TopRejects(5)));
  }

void OnTick()
  {
   UpdateDay();
   ManageOpenTrades();
   datetime bar = iTime(_Symbol, _Period, 0);
   if(bar == 0 || bar == g_lastBar) return;
   if(EvaluateBar()) g_lastBar = bar;   // not-ready data: retry on the next tick instead of dropping the bar
   ShowCourseComment();
  }

double OnTester()
  {
   PrintRejectTally();
   double trades = TesterStatistics(STAT_TRADES);
   double won    = TesterStatistics(STAT_PROFIT_TRADES);
   PrintFormat("=== v2 EDGE: trades=%.0f winRate=%.1f%% profitFactor=%.2f net=%.2f maxDD=%.2f%% ===",
               trades, trades > 0 ? 100.0 * won / trades : 0.0, TesterStatistics(STAT_PROFIT_FACTOR),
               TesterStatistics(STAT_PROFIT), TesterStatistics(STAT_EQUITYDD_PERCENT));
   return(TesterStatistics(STAT_PROFIT_FACTOR));
  }
//+------------------------------------------------------------------+
