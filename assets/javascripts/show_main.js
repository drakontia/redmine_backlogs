// Initialize everything after DOM is loaded
RB.$(function() {  
  var board = RB.Factory.initialize(RB.Taskboard, RB.$('#taskboard'));
  RB.TaskboardUpdater.start();

  // Capture 'click' instead of 'mouseup' so we can preventDefault();
  RB.$('#show_charts').bind('click', RB.showCharts);
  
  RB.$('#assigned_to_id_options').bind('change', function(){
    c = RB.$(this).children(':selected').attr('color');
    RB.$(this).parents('.ui-dialog').css('background-color', c);
    RB.$(this).parents('.ui-dialog').css('background', '-webkit-gradient(linear, left top, left bottom, from(#eee), to('+c+'))');
    RB.$(this).parents('.ui-dialog').css('background', '-moz-linear-gradient(top, #eee, '+c+')');    
    RB.$(this).parents('.ui-dialog').css('filter', 'progid:DXImageTransform.Microsoft.Gradient(Enabled=1,GradientType=0,StartColorStr=#eeeeee,EndColorStr='+c+')');
  });
});

RB.showCharts = function(event){
  event.preventDefault();
  if(RB.$("#charts").length==0){
    RB.$( document.createElement("div") ).attr('id', "charts").appendTo("body");
  }
  RB.$('#charts').html( "<div class='loading'>Loading data...</div>");
  RB.$('#charts').load( RB.urlFor('show_burndown_embedded', { id: RB.constants.sprint_id }) );
  RB.$('#charts').dialog({ 
                        buttons: { "Close": function() { RB.$(this).dialog("close") } },
                        height: 590,
                        modal: true, 
                        title: 'Charts', 
                        width: 710 
                     });
}
