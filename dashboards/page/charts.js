// Small d3 chart kit for the Inforbyte dashboard. Every function draws into `el` from rows it is given,
// replacing what was there, and puts its tooltip inside `el`.
(function () {
  d3.formatDefaultLocale({decimal: ',', thousands: ' ', grouping: [3], currency: ['', ' €']});
  const eurC = new Intl.NumberFormat('pt-PT', {style: 'currency', currency: 'EUR', notation: 'compact', maximumFractionDigits: 1});
  const eur0 = new Intl.NumberFormat('pt-PT', {style: 'currency', currency: 'EUR', maximumFractionDigits: 0});
  const int = new Intl.NumberFormat('pt-PT', {maximumFractionDigits: 0});
  const pct1 = new Intl.NumberFormat('pt-PT', {style: 'percent', maximumFractionDigits: 1});
  const F = {
    eurC: (v) => (v == null || isNaN(v) ? '—' : eurC.format(v)),
    eur: (v) => (v == null || isNaN(v) ? '—' : eur0.format(v)),
    int: (v) => (v == null || isNaN(v) ? '—' : int.format(v)),
    pct: (v) => (v == null || isNaN(v) ? '—' : pct1.format(v / 100)),          // v in percent points (36.0)
    frac: (v) => (v == null || isNaN(v) ? '—' : pct1.format(v)),               // v as fraction (0.36)
    signed: (v) => (v == null || isNaN(v) ? '—' : (v > 0 ? '+' : v < 0 ? '−' : '') + pct1.format(Math.abs(v))),
    pp: (v) => (v == null || isNaN(v) ? '—' : (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(1).replace('.', ',') + ' p.p.'),
  };
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  function frame(el, height, margin) {
    el.replaceChildren();
    const w = Math.max(280, el.clientWidth || 600);
    const svg = d3.select(el).append('svg').attr('width', '100%').attr('viewBox', `0 0 ${w} ${height}`)
      .attr('role', 'img').style('display', 'block').style('overflow', 'visible');
    const tip = d3.select(el).append('div').attr('class', 'ib-tip').attr('hidden', '');
    return {svg, tip, w, h: height, m: margin, iw: w - margin.l - margin.r, ih: height - margin.t - margin.b};
  }
  function showTip(f, event, html) {
    const box = f.tip.node().parentNode.getBoundingClientRect();
    f.tip.attr('hidden', null).html(html);
    const tw = f.tip.node().offsetWidth, x = event.clientX - box.left, y = event.clientY - box.top;
    f.tip.style('left', Math.min(Math.max(0, x + 12), box.width - tw) + 'px').style('top', Math.max(0, y - 40) + 'px');
  }
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));
  function yAxis(f, y, fmt, ticks = 4, right = false) {
    const g = f.svg.append('g').attr('class', 'ib-axis')
      .attr('transform', `translate(${right ? f.m.l + f.iw : f.m.l},0)`)
      .call((right ? d3.axisRight(y) : d3.axisLeft(y)).ticks(ticks).tickFormat(fmt).tickSize(right ? 4 : -f.iw))
      .attr('font-size', null).attr('font-family', null);
    g.select('.domain').remove();
    if (!right) g.selectAll('.tick line').attr('stroke', 'var(--cds-chart-grid)');
    return g;
  }
  function xBand(f, x, every = 1) {
    const g = f.svg.append('g').attr('class', 'ib-axis').attr('transform', `translate(0,${f.m.t + f.ih})`)
      .call(d3.axisBottom(x).tickSizeOuter(0).tickFormat((d, i) => (i % every === 0 ? d : '')))
      .attr('font-size', null).attr('font-family', null);
    g.select('.domain').attr('stroke', 'var(--cds-chart-axis)');
    return g;
  }

  // Vertical bars (one or several series side by side) + optional line on a right axis.
  function bars(el, rows, o) {
    const f = frame(el, o.height || 260, {t: 16, r: o.line ? 48 : 12, b: 28, l: 56});
    const keys = o.series.map((s) => s.key);
    const x0 = d3.scaleBand(rows.map((r) => String(r[o.x])), [f.m.l, f.m.l + f.iw]).padding(0.22);
    const x1 = d3.scaleBand(o.stacked ? ['s'] : keys, [0, x0.bandwidth()]).padding(0.08);
    const max = (o.stacked ? d3.max(rows, (r) => d3.sum(keys, (k) => +r[k] || 0))
                           : d3.max(rows, (r) => d3.max(keys, (k) => +r[k] || 0))) || 1;
    const y = d3.scaleLinear([0, max], [f.m.t + f.ih, f.m.t]).nice();
    yAxis(f, y, o.fmtAxis || F.eurC);
    xBand(f, x0, Math.ceil(rows.length / Math.max(4, Math.floor(f.iw / 46))));
    const g = f.svg.append('g');
    rows.forEach((r) => {
      let base = 0;
      o.series.forEach((s, i) => {
        const v = +r[s.key] || 0, bw = Math.min(32, x1.bandwidth());
        const y0 = o.stacked ? base : 0, y1 = o.stacked ? base + v : v;
        if (o.stacked) base += v;
        g.append('rect').attr('x', x0(String(r[o.x])) + x1(o.stacked ? 's' : s.key) + (x1.bandwidth() - bw) / 2).attr('width', bw)
          .attr('y', y(Math.max(y0, y1))).attr('height', Math.abs(y(y0) - y(y1))).attr('rx', o.stacked ? 0 : 2)
          .attr('fill', s.color || dash.colors[i]).attr('opacity', o.partial && o.partial(r) ? 0.45 : 1);
      });
    });
    let yl;
    if (o.line) {
      yl = o.line.shared ? y : d3.scaleLinear([Math.min(0, d3.min(rows, (r) => +r[o.line.key]) || 0), (d3.max(rows, (r) => +r[o.line.key]) || 1) * 1.15], [f.m.t + f.ih, f.m.t]);
      if (!o.line.shared) yAxis(f, yl, o.line.fmtAxis, 4, true);
      const pts = rows.filter((r) => r[o.line.key] != null);
      f.svg.append('path').datum(pts).attr('fill', 'none').attr('stroke', o.line.color || dash.colors[2]).attr('stroke-width', 2)
        .attr('stroke-linejoin', 'round').attr('stroke-linecap', 'round')
        .attr('d', d3.line().x((r) => x0(String(r[o.x])) + x0.bandwidth() / 2).y((r) => yl(+r[o.line.key])));
      f.svg.append('g').selectAll('circle').data(pts).join('circle').attr('r', 3)
        .attr('cx', (r) => x0(String(r[o.x])) + x0.bandwidth() / 2).attr('cy', (r) => yl(+r[o.line.key]))
        .attr('fill', o.line.color || dash.colors[2]);
    }
    const hover = f.svg.append('g');
    rows.forEach((r) => {
      hover.append('rect').attr('x', x0(String(r[o.x]))).attr('width', x0.bandwidth()).attr('y', f.m.t).attr('height', f.ih)
        .attr('fill', 'transparent')
        .on('mousemove', (ev) => showTip(f, ev, `<div class="ib-tip-h">${esc(r[o.x])}${o.partial && o.partial(r) ? ' (parcial)' : ''}</div>` +
          o.series.map((s, i) => `<div><i style="background:${s.color || dash.colors[i]}"></i>${esc(s.label)} <b>${(s.fmt || F.eur)(+r[s.key])}</b></div>`).join('') +
          (o.line ? `<div><i style="background:${o.line.color || dash.colors[2]}"></i>${esc(o.line.label)} <b>${o.line.fmt(+r[o.line.key])}</b></div>` : '')))
        .on('mouseleave', () => f.tip.attr('hidden', ''));
    });
  }

  // Line over time (x = 'YYYY-MM').
  function line(el, rows, o) {
    const f = frame(el, o.height || 240, {t: 12, r: 16, b: 28, l: 56});
    const parse = d3.utcParse('%Y-%m');
    const pts = rows.map((r) => ({d: parse(r[o.x]), v: +r[o.y] || 0, r}));
    const x = d3.scaleUtc(d3.extent(pts, (p) => p.d), [f.m.l, f.m.l + f.iw]);
    const y = d3.scaleLinear([0, d3.max(pts, (p) => p.v) || 1], [f.m.t + f.ih, f.m.t]).nice();
    yAxis(f, y, o.fmtAxis || F.eurC);
    const gx = f.svg.append('g').attr('class', 'ib-axis').attr('transform', `translate(0,${f.m.t + f.ih})`)
      .call(d3.axisBottom(x).ticks(Math.max(3, Math.floor(f.iw / 70))).tickFormat(d3.utcFormat('%Y')).tickSizeOuter(0))
      .attr('font-size', null).attr('font-family', null);
    gx.select('.domain').attr('stroke', 'var(--cds-chart-axis)');
    const id = 'g' + Math.random().toString(36).slice(2);
    const grad = f.svg.append('defs').append('linearGradient').attr('id', id).attr('x1', 0).attr('x2', 0).attr('y1', 0).attr('y2', 1);
    [[0, .26], [.25, .16], [.5, .08], [.75, .03], [1, 0]].forEach(([o2, a]) => grad.append('stop').attr('offset', o2).attr('style', `stop-color:${dash.colors[0]};stop-opacity:${a}`));
    f.svg.append('path').datum(pts).attr('fill', `url(#${id})`).attr('d', d3.area().x((p) => x(p.d)).y0(y(0)).y1((p) => y(p.v)));
    f.svg.append('path').datum(pts).attr('fill', 'none').attr('stroke', dash.colors[0]).attr('stroke-width', 2)
      .attr('stroke-linejoin', 'round').attr('stroke-linecap', 'round').attr('d', d3.line().x((p) => x(p.d)).y((p) => y(p.v)));
    if (o.avg) {
      const avg = pts.map((p, i) => ({d: p.d, v: i >= 11 ? d3.mean(pts.slice(i - 11, i + 1), (q) => q.v) : null})).filter((p) => p.v != null);
      f.svg.append('path').datum(avg).attr('fill', 'none').attr('stroke', dash.colors[1]).attr('stroke-width', 2)
        .attr('stroke-linejoin', 'round').attr('d', d3.line().x((p) => x(p.d)).y((p) => y(p.v)));
    }
    const dot = f.svg.append('circle').attr('r', 4).attr('fill', dash.colors[0]).attr('hidden', '');
    const fmtM = d3.utcFormat('%m/%Y'), bis = d3.bisector((p) => p.d).center;
    f.svg.append('rect').attr('x', f.m.l).attr('y', f.m.t).attr('width', f.iw).attr('height', f.ih).attr('fill', 'transparent')
      .on('mousemove', (ev) => {
        const p = pts[bis(pts, x.invert(d3.pointer(ev)[0]))];
        dot.attr('hidden', null).attr('cx', x(p.d)).attr('cy', y(p.v));
        showTip(f, ev, `<div class="ib-tip-h">${fmtM(p.d)}</div><div>${esc(o.label)} <b>${F.eur(p.v)}</b></div>` +
          (o.extra ? o.extra(p.r) : ''));
      })
      .on('mouseleave', () => { f.tip.attr('hidden', ''); dot.attr('hidden', ''); });
  }

  // Horizontal bars with a label and a right-hand note per row.
  function hbar(el, rows, o) {
    const rowH = 26, labelW = Math.min(200, Math.max(110, (el.clientWidth || 600) * 0.34));
    const f = frame(el, rows.length * rowH + 8, {t: 4, r: 90, b: 4, l: labelW});
    const x = d3.scaleLinear([0, d3.max(rows, (r) => +r[o.value]) || 1], [f.m.l, f.m.l + f.iw]);
    const g = f.svg.append('g');
    rows.forEach((r, i) => {
      const yy = f.m.t + i * rowH;
      g.append('text').attr('x', f.m.l - 8).attr('y', yy + rowH / 2).attr('dy', '0.35em').attr('text-anchor', 'end')
        .attr('class', 'ib-hlabel').text(String(r[o.label] ?? '').slice(0, 30));
      g.append('rect').attr('x', f.m.l).attr('y', yy + 5).attr('height', rowH - 10).attr('rx', 2)
        .attr('width', Math.max(1, x(+r[o.value]) - f.m.l)).attr('fill', o.color ? o.color(r, i) : dash.colors[0]);
      g.append('text').attr('x', x(+r[o.value]) + 6).attr('y', yy + rowH / 2).attr('dy', '0.35em').attr('class', 'ib-hval')
        .text(o.fmt(r));
      g.append('rect').attr('x', 0).attr('y', yy).attr('width', f.w).attr('height', rowH).attr('fill', 'transparent')
        .on('mousemove', (ev) => showTip(f, ev, `<div class="ib-tip-h">${esc(r[o.label])}</div>${o.tip(r)}`))
        .on('mouseleave', () => f.tip.attr('hidden', ''));
    });
  }

  // Two thin bars per row on one shared scale (e.g. share of sales vs share of margin).
  function hbar2(el, rows, o) {
    const rowH = 40, labelW = Math.min(220, Math.max(120, (el.clientWidth || 600) * 0.38));
    const f = frame(el, rows.length * rowH + 8, {t: 4, r: 52, b: 4, l: labelW});
    const x = d3.scaleLinear([0, d3.max(rows, (r) => Math.max(+r[o.a] || 0, +r[o.b] || 0)) || 1], [f.m.l, f.m.l + f.iw]);
    const g = f.svg.append('g');
    rows.forEach((r, i) => {
      const yy = f.m.t + i * rowH;
      g.append('text').attr('x', f.m.l - 8).attr('y', yy + rowH / 2).attr('dy', '0.35em').attr('text-anchor', 'end')
        .attr('class', 'ib-hlabel').text(String(r[o.label] ?? '').slice(0, 34));
      [[o.a, 0], [o.b, 1]].forEach(([k, j]) => {
        g.append('rect').attr('x', f.m.l).attr('y', yy + 4 + j * 16).attr('height', 12).attr('rx', 2)
          .attr('width', Math.max(1, x(+r[k] || 0) - f.m.l)).attr('fill', dash.colors[j]);
        g.append('text').attr('x', x(+r[k] || 0) + 5).attr('y', yy + 10 + j * 16).attr('dy', '0.35em').attr('class', 'ib-hval')
          .text(o.fmt(+r[k]));
      });
      g.append('rect').attr('x', 0).attr('y', yy).attr('width', f.w).attr('height', rowH).attr('fill', 'transparent')
        .on('mousemove', (ev) => showTip(f, ev, `<div class="ib-tip-h">${esc(r[o.label])}</div>${o.tip(r)}`))
        .on('mouseleave', () => f.tip.attr('hidden', ''));
    });
  }

  // Weekday x hour heatmap.
  function heat(el, rows, o) {
    const days = [1, 2, 3, 4, 5, 6, 0], names = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];
    const hours = d3.range(d3.min(rows, (r) => r.hour), d3.max(rows, (r) => r.hour) + 1);
    const f = frame(el, 7 * 26 + 30, {t: 4, r: 8, b: 26, l: 40});
    const x = d3.scaleBand(hours, [f.m.l, f.m.l + f.iw]).padding(0.08), y = d3.scaleBand(days, [f.m.t, f.m.t + f.ih]).padding(0.08);
    const by = new Map(rows.map((r) => [r.weekday + ':' + r.hour, r]));
    const max = d3.max(rows, (r) => +r[o.value]) || 1;
    const col = d3.interpolateRgb(css('--color-panel') || '#eee', dash.colors[0]);
    const g = f.svg.append('g');
    days.forEach((dd, di) => hours.forEach((hh) => {
      const r = by.get(dd + ':' + hh), v = r ? +r[o.value] : 0;
      g.append('rect').attr('x', x(hh)).attr('y', y(dd)).attr('width', x.bandwidth()).attr('height', y.bandwidth()).attr('rx', 2)
        .attr('fill', v ? col(0.12 + 0.88 * Math.sqrt(v / max)) : 'var(--cds-chart-grid)')
        .on('mousemove', (ev) => showTip(f, ev, `<div class="ib-tip-h">${names[di]}, ${hh}h</div><div>Faturas <b>${F.int(v)}</b></div><div>Vendas <b>${F.eur(r ? r.net_sales : 0)}</b></div>`))
        .on('mouseleave', () => f.tip.attr('hidden', ''));
    }));
    days.forEach((dd, di) => g.append('text').attr('x', f.m.l - 6).attr('y', y(dd) + y.bandwidth() / 2).attr('dy', '0.35em')
      .attr('text-anchor', 'end').attr('class', 'ib-hlabel').text(names[di]));
    hours.forEach((hh, i) => { if (i % Math.ceil(hours.length / Math.floor(f.iw / 26)) === 0)
      g.append('text').attr('x', x(hh) + x.bandwidth() / 2).attr('y', f.m.t + f.ih + 16).attr('text-anchor', 'middle').attr('class', 'ib-hlabel').text(hh + 'h'); });
  }

  // Fill a <tbody> from rows: cols = [{key, fmt?, cls?}]; rowKey = column for <tr data-key>.
  function tbody(el, rows, cols, rowKey) {
    el.replaceChildren(...rows.map((r) => {
      const tr = document.createElement('tr');
      if (rowKey) tr.dataset.key = r[rowKey];
      cols.forEach((c) => { const td = document.createElement('td'); td.textContent = c.fmt ? c.fmt(r[c.key], r) : (r[c.key] ?? ''); if (c.cls) td.className = c.cls; tr.append(td); });
      return tr;
    }));
  }

  window.IB = {F, bars, line, hbar, hbar2, heat, tbody};
})();
