// @vitest-environment jsdom
import {afterEach,expect,it,vi} from 'vitest'
import {cleanup,fireEvent,render,screen,within} from '@testing-library/react'
import {GlobalSearchDialog} from './GlobalSearchDialog'
afterEach(cleanup)
const notes=[
  {id:'1',title:'첫 노트',notebook_id:'a',trashed:false,excerpt:'일정 확인',tags:['업무']},
  {id:'2',title:'<script>제목</script>',notebook_id:'b',trashed:false,tags:['개인']},
  {id:'3',title:'휴지통 문서',notebook_id:'a',trashed:true,tags:['업무']},
]
it('searches metadata across notebooks and excludes trash while rendering titles as text',()=>{
  const {container}=render(<GlobalSearchDialog notes={notes} notebooks={[]} loading={false} onSelect={vi.fn()} onClose={vi.fn()}/>)
  const dialog=screen.getByRole('dialog',{name:'전체 노트 검색'})
  expect(container.querySelector('script')).toBeNull()
  expect(within(dialog).getByRole('button',{name:/<script>제목/})).toBeTruthy()
  expect(within(dialog).queryByRole('button',{name:/휴지통/})).toBeNull()
  fireEvent.change(within(dialog).getByRole('searchbox'),{target:{value:'업무'}})
  expect(within(dialog).getByRole('button',{name:/첫 노트/})).toBeTruthy()
  expect(within(dialog).queryByRole('button',{name:/<script>/})).toBeNull()
})
it('includes matches from the current note body version alongside metadata', async () => {
  const searchBody = vi.fn(async () => ({
    matches: [{id:'2', version:'v2'}, {id:'4', version:'old'}],
    indexed: 2, total: 3,
  }))
  render(<GlobalSearchDialog notes={[{...notes[0],version:'v1'}, {...notes[1],version:'v2'},
    {...notes[2],id:'4',title:'다른 노트',version:'v3',trashed:false,tags:[]}]} notebooks={[]} loading={false}
    onSelect={vi.fn()} onClose={vi.fn()} searchBody={searchBody}/>)
  fireEvent.change(screen.getByRole('searchbox'), {target:{value:'업무'}})
  expect(await screen.findByRole('button',{name:/<script>제목/})).toBeTruthy()
  expect(screen.getByRole('button',{name:/첫 노트/})).toBeTruthy()
  expect(screen.queryByRole('button',{name:/다른 노트/})).toBeNull()
  expect(screen.getByRole('status').textContent).toContain('2/3')
})
it('keeps the dialog open on a blocked save and traps keyboard focus',async()=>{
  const select=vi.fn(async()=>false),close=vi.fn()
  render(<GlobalSearchDialog notes={notes} notebooks={[]} loading={false} onSelect={select} onClose={close}/>)
  const first=screen.getByRole('button',{name:'검색 닫기'})
  const last=screen.getAllByRole('button').at(-1)!
  first.focus();fireEvent.keyDown(first,{key:'Tab',shiftKey:true});expect(document.activeElement).toBe(last)
  fireEvent.keyDown(last,{key:'Tab'});expect(document.activeElement).toBe(first)
  fireEvent.click(screen.getByRole('button',{name:/첫 노트/}))
  expect(await screen.findByRole('alert')).toHaveProperty('textContent','현재 노트의 저장을 확인한 뒤 다시 선택해 주세요.')
  expect(select).toHaveBeenCalledOnce();expect(close).not.toHaveBeenCalled()
  fireEvent.keyDown(screen.getByRole('dialog'),{key:'Escape'});expect(close).toHaveBeenCalledOnce()
})
