// App shell + routes. Pages live in src/pages; shared pieces in src/components and src/lib.
import { useRoute } from '@/lib/router'
import { Shell } from '@/components/Shell'
import Landing from '@/pages/Landing'
import Markets from '@/pages/Markets'
import Trade from '@/pages/Trade'
import Portfolio from '@/pages/Portfolio'
import BucketNew from '@/pages/BucketNew'
import BucketDetail from '@/pages/BucketDetail'

export default function App() {
  const [page, arg] = useRoute()
  let view
  if (!page) view = <Landing />
  else if (page === 'markets') view = <Markets />
  else if (page === 'trade') view = <Trade symbol={arg ?? 'EURC'} />
  else if (page === 'portfolio') view = <Portfolio />
  else if (page === 'buckets' && arg === 'new') view = <BucketNew />
  else if (page === 'buckets' && arg) view = <BucketDetail address={arg as `0x${string}`} />
  else view = <Landing />
  return <Shell>{view}</Shell>
}
